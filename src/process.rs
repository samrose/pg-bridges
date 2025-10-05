use nix::sys::signal::{self, Signal};
use nix::unistd::Pid;
use pgrx::{log, error};
use std::collections::VecDeque;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::time::sleep;

pub struct ProcessManager {
    executable_path: String,
    socket_path: String,
    memory_limit_mb: u64,
    max_restarts: usize,
    process: Arc<Mutex<Option<Child>>>,
    restart_times: Arc<Mutex<VecDeque<Instant>>>,
    restart_backoff: Arc<Mutex<Duration>>,
}

impl ProcessManager {
    pub fn new(
        executable_path: String,
        socket_path: String,
        memory_limit_mb: u64,
        max_restarts: usize,
    ) -> Self {
        Self {
            executable_path,
            socket_path,
            memory_limit_mb,
            max_restarts,
            process: Arc::new(Mutex::new(None)),
            restart_times: Arc::new(Mutex::new(VecDeque::new())),
            restart_backoff: Arc::new(Mutex::new(Duration::from_secs(1))),
        }
    }

    pub async fn start(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut process = self.process.lock().await;

        if process.is_some() {
            return Err("Process already running".into());
        }

        let socket_parent = Path::new(&self.socket_path).parent();
        if let Some(parent) = socket_parent {
            std::fs::create_dir_all(parent)?;
        }

        if Path::new(&self.socket_path).exists() {
            std::fs::remove_file(&self.socket_path)?;
        }

        log!("Starting Elixir process: {}", self.executable_path);

        let mut cmd = Command::new(&self.executable_path);
        cmd.env("ELIXIR_SOCKET_PATH", &self.socket_path)
            .env("ELIXIR_MEMORY_LIMIT_MB", self.memory_limit_mb.to_string());

        let memory_limit_mb = self.memory_limit_mb;
        unsafe {
            use libc::{rlimit, setrlimit, RLIMIT_AS, RLIMIT_NOFILE};

            cmd.pre_exec(move || {
                let mem_limit = rlimit {
                    rlim_cur: (memory_limit_mb * 1024 * 1024) as _,
                    rlim_max: (memory_limit_mb * 1024 * 1024) as _,
                };
                setrlimit(RLIMIT_AS, &mem_limit);

                let fd_limit = rlimit {
                    rlim_cur: 1024,
                    rlim_max: 1024,
                };
                setrlimit(RLIMIT_NOFILE, &fd_limit);

                Ok(())
            });
        }

        let child = cmd.spawn()?;
        let pid = child.id();
        log!("Elixir process started with PID: {}", pid);

        *process = Some(child);
        Ok(())
    }

    pub async fn stop(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut process = self.process.lock().await;

        if let Some(mut child) = process.take() {
            let pid = child.id();
            log!("Stopping Elixir process with PID: {}", pid);

            if let Err(e) = signal::kill(Pid::from_raw(pid as i32), Signal::SIGTERM) {
                error!("Failed to send SIGTERM: {}", e);
            }

            // Wait for graceful termination or force kill
            let wait_result = tokio::time::timeout(
                Duration::from_secs(5),
                tokio::task::spawn_blocking(move || child.wait())
            ).await;

            match wait_result {
                Ok(Ok(Ok(_))) => {
                    log!("Elixir process terminated gracefully");
                }
                _ => {
                    log!("Process didn't terminate gracefully within timeout");
                    // Process handle moved, can't kill here
                    let _ = signal::kill(Pid::from_raw(pid as i32), Signal::SIGKILL);
                }
            }
        }

        if Path::new(&self.socket_path).exists() {
            std::fs::remove_file(&self.socket_path)?;
        }

        Ok(())
    }

    pub async fn restart(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let now = Instant::now();
        let mut restart_times = self.restart_times.lock().await;

        restart_times.retain(|t| now.duration_since(*t) < Duration::from_secs(60));

        if restart_times.len() >= self.max_restarts {
            return Err(format!(
                "Maximum restart attempts ({}) reached in 60s window",
                self.max_restarts
            )
            .into());
        }

        restart_times.push_back(now);
        drop(restart_times);

        let mut backoff = self.restart_backoff.lock().await;
        log!("Restarting Elixir process with backoff: {:?}", *backoff);

        self.stop().await?;
        sleep(*backoff).await;
        self.start().await?;

        *backoff = std::cmp::min(*backoff * 2, Duration::from_secs(30));

        Ok(())
    }

    pub async fn is_running(&self) -> bool {
        let mut process = self.process.lock().await;

        if let Some(child) = process.as_mut() {
            match child.try_wait() {
                Ok(None) => true,
                Ok(Some(status)) => {
                    log!("Elixir process exited with status: {:?}", status);
                    *process = None;
                    false
                }
                Err(e) => {
                    log!("Error checking process status: {}", e);
                    false
                }
            }
        } else {
            false
        }
    }

    pub async fn get_memory_usage(&self) -> Option<u64> {
        let process = self.process.lock().await;

        if let Some(child) = process.as_ref() {
            let pid = child.id();

            #[cfg(target_os = "linux")]
            {
                if let Ok(status) = std::fs::read_to_string(format!("/proc/{}/status", pid)) {
                    for line in status.lines() {
                        if line.starts_with("VmRSS:") {
                            if let Some(kb_str) = line.split_whitespace().nth(1) {
                                if let Ok(kb) = kb_str.parse::<u64>() {
                                    return Some(kb * 1024);
                                }
                            }
                        }
                    }
                }
            }

            #[cfg(target_os = "macos")]
            {
                use std::process::Command;
                if let Ok(output) = Command::new("ps")
                    .args(&["-o", "rss=", "-p", &pid.to_string()])
                    .output()
                {
                    if let Ok(s) = String::from_utf8(output.stdout) {
                        if let Ok(kb) = s.trim().parse::<u64>() {
                            return Some(kb * 1024);
                        }
                    }
                }
            }
        }

        None
    }
}