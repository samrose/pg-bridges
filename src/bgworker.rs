use pgrx::prelude::*;
use pgrx::{bgworkers::*, log, error};
use crate::{ProcessManager, IpcClient, TOKIO_RUNTIME, update_shared_state};
use std::sync::Arc;
use std::time::Duration;
use std::sync::atomic::Ordering;
use once_cell::sync::Lazy;
use std::sync::RwLock;

// Global state accessible to SQL functions
static PROCESS_MANAGER: Lazy<Arc<RwLock<Option<Arc<ProcessManager>>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

static IPC_CLIENT: Lazy<Arc<RwLock<Option<Arc<IpcClient>>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

#[no_mangle]
pub extern "C" fn elixir_bgworker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    log!("Starting Elixir background worker");

    // Get configuration from GUCs
    let executable_path = get_guc_string("elixir.executable_path")
        .unwrap_or_else(|| "/usr/local/lib/postgresql/elixir_sidecar".to_string());
    let socket_path = get_guc_string("elixir.socket_path")
        .unwrap_or_else(|| {
            std::env::var("HOME")
                .map(|h| format!("{}/pg_elixir.sock", h))
                .unwrap_or_else(|_| "/tmp/pg_elixir.sock".to_string())
        });
    let memory_limit_mb = get_guc_int("elixir.memory_limit_mb")
        .unwrap_or(512) as u64;
    let max_restarts = get_guc_int("elixir.max_restarts")
        .unwrap_or(3) as usize;

    log!("Elixir executable: {}", executable_path);
    log!("Socket path: {}", socket_path);
    log!("Memory limit: {} MB", memory_limit_mb);
    log!("Max restarts: {}", max_restarts);

    // Use the shared TOKIO_RUNTIME instead of creating a new one
    let result = TOKIO_RUNTIME.block_on(async {
        // Initialize process manager and IPC client
        let process_manager = Arc::new(ProcessManager::new(
            executable_path.clone(),
            socket_path.clone(),
            memory_limit_mb,
            max_restarts,
        ));

        let ipc_client = Arc::new(IpcClient::new(socket_path.clone()));

        // Store in global state
        {
            let mut pm = PROCESS_MANAGER.write().unwrap();
            *pm = Some(process_manager.clone());
        }
        {
            let mut ipc = IPC_CLIENT.write().unwrap();
            *ipc = Some(ipc_client.clone());
        }

        // Start the Elixir process
        if let Err(e) = process_manager.start().await {
            log!("Failed to start Elixir process: {}", e);
            return Err(());
        }

        log!("Elixir process started successfully");

        // Update shared memory with Elixir PID
        if let Some(child) = process_manager.process.lock().await.as_ref() {
            update_shared_state(|state| {
                state.elixir_pid.store(child.id() as i32, Ordering::Relaxed);
            });
        }

        // Wait for socket to be available
        for i in 0..30 {
            if std::path::Path::new(&socket_path).exists() {
                log!("Socket available at {}", socket_path);
                break;
            }
            if i == 29 {
                log!("Socket not available after 30 seconds");
                let _ = process_manager.stop().await;
                return Err(());
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }

        // Connect IPC client
        if let Err(e) = ipc_client.connect().await {
            log!("Failed to connect IPC client: {}", e);
            let _ = process_manager.stop().await;
            return Err(());
        }

        log!("Elixir sidecar started and connected successfully");

        // Mark as healthy in shared memory
        update_shared_state(|state| {
            state.is_healthy.store(1, Ordering::Relaxed);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            state.last_ping_time.store(now, Ordering::Relaxed);
        });

        // Health check loop
        loop {
            tokio::time::sleep(Duration::from_secs(10)).await;

            let is_running = process_manager.is_running().await;
            if !is_running {
                log!("Elixir process is no longer running");
                update_shared_state(|state| {
                    state.is_healthy.store(0, Ordering::Relaxed);
                });
                break;
            }

            // Periodic ping to check IPC health
            match ipc_client.ping().await {
                Ok(_) => {
                    // Update last successful ping time
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_secs();
                    update_shared_state(|state| {
                        state.is_healthy.store(1, Ordering::Relaxed);
                        state.last_ping_time.store(now, Ordering::Relaxed);
                    });
                }
                Err(e) => {
                    log!("IPC ping failed: {}, attempting reconnect", e);
                    update_shared_state(|state| {
                        state.is_healthy.store(0, Ordering::Relaxed);
                    });
                    // Try to reconnect
                    if let Err(e) = ipc_client.reconnect().await {
                        log!("Failed to reconnect IPC: {}, shutting down", e);
                        break;
                    }
                }
            }
        }

        log!("Elixir background worker shutting down");
        let _ = process_manager.stop().await;
        Ok(())
    });

    if result.is_err() {
        log!("Background worker exited with error");
    }

    // Clear global state
    {
        let mut pm = PROCESS_MANAGER.write().unwrap();
        *pm = None;
    }
    {
        let mut ipc = IPC_CLIENT.write().unwrap();
        *ipc = None;
    }
}

// Helper functions to get GUC values
fn get_guc_string(name: &str) -> Option<String> {
    unsafe {
        let c_name = std::ffi::CString::new(name).ok()?;
        let value = pg_sys::GetConfigOption(c_name.as_ptr(), false, false);
        if value.is_null() {
            None
        } else {
            let c_str = std::ffi::CStr::from_ptr(value);
            c_str.to_str().ok().map(|s| s.to_string())
        }
    }
}

fn get_guc_int(name: &str) -> Option<i32> {
    get_guc_string(name)?.parse().ok()
}

// Export global accessors for SQL functions
pub fn get_process_manager() -> Option<Arc<ProcessManager>> {
    PROCESS_MANAGER.read().unwrap().clone()
}

pub fn get_ipc_client() -> Option<Arc<IpcClient>> {
    IPC_CLIENT.read().unwrap().clone()
}