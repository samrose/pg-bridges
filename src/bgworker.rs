use pgrx::prelude::*;
use pgrx::{bgworkers::*, log, error};
use std::sync::Arc;
use std::time::Duration;

use crate::ipc::IpcClient;
use crate::process::ProcessManager;

// Store process manager and IPC client globally
static mut PROCESS_MANAGER: Option<Arc<ProcessManager>> = None;
static mut IPC_CLIENT: Option<Arc<IpcClient>> = None;

#[no_mangle]
pub extern "C" fn elixir_bgworker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    log!("Starting Elixir background worker");

    // Get configuration from GUCs
    let executable_path = get_guc_string("elixir.executable_path")
        .unwrap_or_else(|| "/usr/local/lib/postgresql/elixir_sidecar".to_string());
    let socket_path = get_guc_string("elixir.socket_path")
        .unwrap_or_else(|| "/tmp/pg_elixir.sock".to_string());
    let memory_limit_mb = get_guc_int("elixir.memory_limit_mb").unwrap_or(2048) as u64;
    let max_restarts = get_guc_int("elixir.max_restarts").unwrap_or(5) as usize;

    log!("Elixir executable: {}", executable_path);
    log!("Socket path: {}", socket_path);

    // Initialize process manager and IPC client
    let process_manager = Arc::new(ProcessManager::new(
        executable_path.clone(),
        socket_path.clone(),
        memory_limit_mb,
        max_restarts,
    ));

    let ipc_client = Arc::new(IpcClient::new(socket_path.clone()));

    // Store globally for access from SQL functions
    unsafe {
        PROCESS_MANAGER = Some(process_manager.clone());
        IPC_CLIENT = Some(ipc_client.clone());
    }

    // Start Elixir process in a separate runtime
    let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");

    rt.block_on(async {
        log!("Starting Elixir sidecar process...");

        if let Err(e) = process_manager.start().await {
            error!("Failed to start Elixir process: {}", e);
            return;
        }

        // Wait for socket to be available
        for i in 0..30 {
            if std::path::Path::new(&socket_path).exists() {
                log!("Socket available, connecting IPC client...");
                break;
            }
            if i == 29 {
                error!("Socket not available after 30 seconds");
                return;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }

        // Connect IPC client
        if let Err(e) = ipc_client.connect().await {
            error!("Failed to connect IPC client: {}", e);
            return;
        }

        log!("Elixir sidecar connected successfully");

        // Health check loop
        let mut counter = 0;
        loop {
            tokio::time::sleep(Duration::from_secs(10)).await;
            counter += 1;

            // Check if process is still running
            if !process_manager.is_running().await {
                error!("Elixir process died, attempting restart...");
                if let Err(e) = process_manager.restart().await {
                    error!("Failed to restart Elixir process: {}", e);
                    break;
                }
                if let Err(e) = ipc_client.reconnect().await {
                    error!("Failed to reconnect IPC client: {}", e);
                    break;
                }
            }

            // Periodic health check
            if counter % 6 == 0 {
                if let Err(e) = ipc_client.ping().await {
                    error!("Health check failed: {}", e);
                    if let Err(e) = process_manager.restart().await {
                        error!("Failed to restart after health check failure: {}", e);
                        break;
                    }
                } else {
                    log!("Health check passed - {} minutes uptime", counter / 6);
                }
            }
        }

        log!("Elixir background worker shutting down");
        let _ = process_manager.stop().await;
    });
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
    unsafe { PROCESS_MANAGER.clone() }
}

pub fn get_ipc_client() -> Option<Arc<IpcClient>> {
    unsafe { IPC_CLIENT.clone() }
}