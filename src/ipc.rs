use crate::protocol::{Request, Response};
use bytes::{Buf, BufMut, BytesMut};
use dashmap::DashMap;
use pgrx::log;
use serde_json::Value;
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::{Mutex, RwLock};
use tokio::time::{timeout, sleep};
use uuid::Uuid;

const MAX_MESSAGE_SIZE: usize = 16 * 1024 * 1024; // 16MB
const DEFAULT_TIMEOUT_MS: u64 = 30000;
const MAX_CONSECUTIVE_FAILURES: usize = 5;
const CIRCUIT_BREAKER_RESET_MS: u64 = 30000;

#[derive(Error, Debug)]
pub enum IpcError {
    #[error("Connection error: {0}")]
    ConnectionError(String),
    #[error("Timeout error")]
    Timeout,
    #[error("Protocol error: {0}")]
    ProtocolError(String),
    #[error("Circuit breaker open")]
    CircuitBreakerOpen,
    #[error("IO error: {0}")]
    IoError(#[from] io::Error),
    #[error("Serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),
}

pub struct IpcClient {
    socket_path: String,
    stream: Arc<RwLock<Option<UnixStream>>>,
    pending_requests: Arc<DashMap<Uuid, tokio::sync::oneshot::Sender<Result<Response, IpcError>>>>,
    async_results: Arc<DashMap<Uuid, Value>>,
    request_count: Arc<AtomicU64>,
    consecutive_failures: Arc<AtomicUsize>,
    circuit_breaker_until: Arc<Mutex<Option<std::time::Instant>>>,
}

impl IpcClient {
    pub fn new(socket_path: String) -> Self {
        Self {
            socket_path,
            stream: Arc::new(RwLock::new(None)),
            pending_requests: Arc::new(DashMap::new()),
            async_results: Arc::new(DashMap::new()),
            request_count: Arc::new(AtomicU64::new(0)),
            consecutive_failures: Arc::new(AtomicUsize::new(0)),
            circuit_breaker_until: Arc::new(Mutex::new(None)),
        }
    }

    pub async fn connect(&self) -> Result<(), IpcError> {
        self.connect_with_retry(3).await
    }

    async fn connect_with_retry(&self, max_retries: usize) -> Result<(), IpcError> {
        for attempt in 0..max_retries {
            if attempt > 0 {
                let backoff = Duration::from_millis(100 * 2_u64.pow(attempt as u32));
                sleep(backoff).await;
            }

            match self.try_connect().await {
                Ok(()) => {
                    self.consecutive_failures.store(0, Ordering::SeqCst);
                    return Ok(());
                }
                Err(e) if attempt == max_retries - 1 => return Err(e),
                Err(e) => {
                    log::error!("Connection attempt {} failed: {}", attempt + 1, e);
                }
            }
        }

        Err(IpcError::ConnectionError("Max retries exceeded".to_string()))
    }

    async fn try_connect(&self) -> Result<(), IpcError> {
        let socket_path = Path::new(&self.socket_path);

        if !socket_path.exists() {
            return Err(IpcError::ConnectionError(format!(
                "Socket path does not exist: {}",
                self.socket_path
            )));
        }

        let stream = UnixStream::connect(&self.socket_path).await?;
        stream.set_nodelay(true)?;

        let mut stream_lock = self.stream.write().await;
        *stream_lock = Some(stream);

        log!("Connected to Elixir sidecar at {}", self.socket_path);

        self.spawn_reader();

        Ok(())
    }

    pub async fn reconnect(&self) -> Result<(), IpcError> {
        let mut stream = self.stream.write().await;
        *stream = None;
        drop(stream);

        self.connect().await
    }

    fn spawn_reader(&self) {
        let stream_clone = self.stream.clone();
        let pending_requests = self.pending_requests.clone();
        let async_results = self.async_results.clone();

        tokio::spawn(async move {
            loop {
                let mut buffer = BytesMut::with_capacity(4096);

                let stream_opt = {
                    let stream_lock = stream_clone.read().await;
                    stream_lock.as_ref().map(|s| Ok(s.clone()))
                };

                let mut stream = match stream_opt {
                    Some(Ok(s)) => s,
                    _ => {
                        sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                };

                match read_message(&mut stream, &mut buffer).await {
                    Ok(Some(response)) => {
                        if let Some((_, sender)) = pending_requests.remove(&response.id) {
                            let _ = sender.send(Ok(response.clone()));
                        } else {
                            async_results.insert(response.id, response.result);
                        }
                    }
                    Ok(None) => {
                        sleep(Duration::from_millis(10)).await;
                    }
                    Err(e) => {
                        log::error!("Error reading from socket: {}", e);
                        let mut stream_lock = stream_clone.write().await;
                        *stream_lock = None;
                        break;
                    }
                }
            }
        });
    }

    async fn check_circuit_breaker(&self) -> Result<(), IpcError> {
        let mut breaker = self.circuit_breaker_until.lock().await;

        if let Some(until) = *breaker {
            if std::time::Instant::now() < until {
                return Err(IpcError::CircuitBreakerOpen);
            } else {
                *breaker = None;
                self.consecutive_failures.store(0, Ordering::SeqCst);
            }
        }

        Ok(())
    }

    async fn handle_failure(&self) {
        let failures = self.consecutive_failures.fetch_add(1, Ordering::SeqCst) + 1;

        if failures >= MAX_CONSECUTIVE_FAILURES {
            let mut breaker = self.circuit_breaker_until.lock().await;
            *breaker = Some(
                std::time::Instant::now() + Duration::from_millis(CIRCUIT_BREAKER_RESET_MS)
            );
            log::error!("Circuit breaker opened after {} consecutive failures", failures);
        }
    }

    pub async fn send_request(&self, request: Request) -> Result<Response, IpcError> {
        self.check_circuit_breaker().await?;

        let timeout_ms = request.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
        let (tx, rx) = tokio::sync::oneshot::channel();

        self.pending_requests.insert(request.id, tx);
        self.request_count.fetch_add(1, Ordering::SeqCst);

        let result = timeout(
            Duration::from_millis(timeout_ms),
            self.send_and_wait(request, rx),
        )
        .await;

        match result {
            Ok(Ok(response)) => {
                self.consecutive_failures.store(0, Ordering::SeqCst);
                Ok(response)
            }
            Ok(Err(e)) => {
                self.handle_failure().await;
                Err(e)
            }
            Err(_) => {
                self.handle_failure().await;
                self.pending_requests.remove(&request.id);
                Err(IpcError::Timeout)
            }
        }
    }

    async fn send_and_wait(
        &self,
        request: Request,
        rx: tokio::sync::oneshot::Receiver<Result<Response, IpcError>>,
    ) -> Result<Response, IpcError> {
        let stream_opt = {
            let stream_lock = self.stream.read().await;
            stream_lock.as_ref().map(|s| s.clone())
        };

        let mut stream = stream_opt
            .ok_or_else(|| IpcError::ConnectionError("Not connected".to_string()))?
;

        write_message(&mut stream, &request).await?;

        rx.await
            .map_err(|_| IpcError::ConnectionError("Response channel closed".to_string()))?
    }

    pub async fn send_request_async(&self, request: Request) -> Result<Uuid, IpcError> {
        self.check_circuit_breaker().await?;

        let request_id = request.id;
        let stream_opt = {
            let stream_lock = self.stream.read().await;
            stream_lock.as_ref().map(|s| s.clone())
        };

        let mut stream = stream_opt
            .ok_or_else(|| IpcError::ConnectionError("Not connected".to_string()))?
;

        write_message(&mut stream, &request).await?;
        self.request_count.fetch_add(1, Ordering::SeqCst);

        Ok(request_id)
    }

    pub fn get_async_result(&self, request_id: &Uuid) -> Option<Value> {
        self.async_results.remove(request_id).map(|(_, v)| v)
    }

    pub async fn ping(&self) -> Result<(), IpcError> {
        let request = Request {
            id: Uuid::new_v4(),
            function: "ping".to_string(),
            args: Value::Null,
            timeout_ms: Some(5000),
        };

        self.send_request(request).await?;
        Ok(())
    }
}

async fn write_message<T: serde::Serialize>(
    stream: &mut UnixStream,
    message: &T,
) -> Result<(), IpcError> {
    let json_bytes = serde_json::to_vec(message)?;

    if json_bytes.len() > MAX_MESSAGE_SIZE {
        return Err(IpcError::ProtocolError("Message too large".to_string()));
    }

    let mut buffer = BytesMut::with_capacity(4 + json_bytes.len());
    buffer.put_u32(json_bytes.len() as u32);
    buffer.put_slice(&json_bytes);

    stream.write_all(&buffer).await?;
    stream.flush().await?;

    Ok(())
}

async fn read_message(
    stream: &mut UnixStream,
    buffer: &mut BytesMut,
) -> Result<Option<Response>, IpcError> {
    if buffer.len() < 4 {
        let mut len_buf = [0u8; 4];
        match stream.read_exact(&mut len_buf).await {
            Ok(_) => buffer.put_slice(&len_buf),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e.into()),
        }
    }

    let len = buffer.get_u32() as usize;

    if len > MAX_MESSAGE_SIZE {
        return Err(IpcError::ProtocolError("Message too large".to_string()));
    }

    let mut message_buf = vec![0u8; len];
    stream.read_exact(&mut message_buf).await?;

    let response: Response = serde_json::from_slice(&message_buf)?;
    Ok(Some(response))
}