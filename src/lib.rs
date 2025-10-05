use pgrx::prelude::*;
use pgrx::bgworkers::BackgroundWorkerBuilder;
use uuid::Uuid;
use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};

mod bgworker;
mod ipc;
mod process;
mod protocol;

pub use bgworker::*;
pub use ipc::*;
pub use process::*;
pub use protocol::*;

pgrx::pg_module_magic!();

// Shared memory structure for cross-process communication
#[repr(C)]
pub struct ElixirSharedState {
    pub elixir_pid: AtomicI32,           // PID of Elixir process
    pub is_healthy: AtomicI32,            // 1 = healthy, 0 = unhealthy
    pub last_ping_time: AtomicU64,        // Unix timestamp of last successful ping
    pub restart_count: AtomicI32,         // Number of times restarted
}

impl ElixirSharedState {
    pub const fn new() -> Self {
        Self {
            elixir_pid: AtomicI32::new(0),
            is_healthy: AtomicI32::new(0),
            last_ping_time: AtomicU64::new(0),
            restart_count: AtomicI32::new(0),
        }
    }
}

// Global reference to shared memory
static mut SHARED_STATE: Option<&'static ElixirSharedState> = None;

// Helper to update shared state
pub fn update_shared_state<F>(updater: F)
where
    F: FnOnce(&ElixirSharedState),
{
    unsafe {
        if let Some(state) = SHARED_STATE {
            updater(state);
        }
    }
}

// Helper to read shared state
pub fn get_shared_state() -> Option<&'static ElixirSharedState> {
    unsafe { SHARED_STATE }
}

// Shared tokio runtime for all SQL function calls
static TOKIO_RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("pg_elixir_worker")
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime")
});

// static ELIXIR_STATE: Lazy<Arc<RwLock<Option<ElixirState>>>> = Lazy::new(|| Arc::new(RwLock::new(None)));

// #[derive(Clone)]
// pub struct ElixirState {
//     pub process_manager: Arc<ProcessManager>,
//     pub ipc_client: Arc<IpcClient>,
//     pub health_stats: Arc<RwLock<HealthStats>>,
// }

// Simplified version without complex state management

#[pg_extern]
fn elixir_call(function_name: &str, args: pgrx::JsonB) -> String {
    // Get socket path from postgresql.conf setting
    let socket_path = unsafe {
        let c_name = std::ffi::CString::new("elixir.socket_path").unwrap();
        let value = pg_sys::GetConfigOption(c_name.as_ptr(), false, false);
        if value.is_null() {
            // Fallback to default from config or home directory
            std::env::var("HOME")
                .map(|h| format!("{}/pg_elixir.sock", h))
                .unwrap_or_else(|_| "/tmp/pg_elixir.sock".to_string())
        } else {
            let c_str = std::ffi::CStr::from_ptr(value);
            c_str.to_str().unwrap_or("/tmp/pg_elixir.sock").to_string()
        }
    };

    // Create a new IPC client for this call
    let ipc_client = std::sync::Arc::new(IpcClient::new(socket_path));

    let args_value: serde_json::Value = serde_json::from_str(&args.0.to_string())
        .unwrap_or(serde_json::Value::Null);

    let request = Request::new(function_name.to_string(), args_value);

    // Use shared runtime
    let result = TOKIO_RUNTIME.block_on(async {
        // Connect to socket
        if let Err(e) = ipc_client.connect().await {
            return Err(format!("Connection error: {}", e));
        }

        // Send request
        match ipc_client.send_request(request).await {
            Ok(r) => Ok(r),
            Err(e) => Err(format!("{}", e))
        }
    });

    match result {
        Ok(response) if response.success => {
            serde_json::to_string(&response.result)
                .unwrap_or_else(|_| "{}".to_string())
        }
        Ok(response) => {
            format!(
                "{{\"error\": \"{}\"}}",
                response.error.unwrap_or_else(|| "Unknown error".to_string())
            )
        }
        Err(e) => format!("{{\"error\": \"{}\"}}", e),
    }
}

#[pg_extern]
fn elixir_call_async(function_name: &str, args: pgrx::JsonB) -> String {
    let ipc_client = match get_ipc_client() {
        Some(client) => client,
        None => return format!("{{\"error\": \"IPC client not initialized\"}}"),
    };

    let args_value: serde_json::Value = serde_json::from_str(&args.0.to_string())
        .unwrap_or(serde_json::Value::Null);

    let request = Request::new(function_name.to_string(), args_value);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| {
            tokio::runtime::Runtime::new()
                .expect("Failed to create runtime")
                .handle()
                .clone()
        });

    match rt.block_on(ipc_client.send_request_async(request)) {
        Ok(id) => id.to_string(),
        Err(e) => format!("{{\"error\": \"{}\"}}", e),
    }
}

#[pg_extern]
fn elixir_get_result(request_id: &str) -> String {
    let ipc_client = match get_ipc_client() {
        Some(client) => client,
        None => return format!("{{\"error\": \"IPC client not initialized\"}}"),
    };

    let uuid = match Uuid::parse_str(request_id) {
        Ok(u) => u,
        Err(_) => return format!("{{\"error\": \"Invalid UUID\"}}"),
    };

    match ipc_client.get_async_result(&uuid) {
        Some(result) => serde_json::to_string(&result)
            .unwrap_or_else(|_| "{}".to_string()),
        None => format!("{{\"status\": \"pending\"}}"),
    }
}

#[pg_extern]
fn elixir_health() -> String {
    unsafe {
        match SHARED_STATE {
            Some(state) => {
                let pid = state.elixir_pid.load(Ordering::Relaxed);
                let is_healthy = state.is_healthy.load(Ordering::Relaxed) == 1;
                let last_ping = state.last_ping_time.load(Ordering::Relaxed);
                let restart_count = state.restart_count.load(Ordering::Relaxed);

                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();

                let health = serde_json::json!({
                    "status": if is_healthy { "healthy" } else { "unhealthy" },
                    "elixir_pid": pid,
                    "last_ping_seconds_ago": if last_ping > 0 { now - last_ping } else { 0 },
                    "restart_count": restart_count,
                });

                serde_json::to_string(&health).unwrap_or_else(|_| "{}".to_string())
            }
            None => format!("{{\"status\": \"shared_memory_not_initialized\"}}")
        }
    }
}

#[pg_extern]
fn elixir_restart() -> bool {
    let pm = match get_process_manager() {
        Some(pm) => pm,
        None => return false,
    };

    let ipc = match get_ipc_client() {
        Some(ipc) => ipc,
        None => return false,
    };

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| {
            tokio::runtime::Runtime::new()
                .expect("Failed to create runtime")
                .handle()
                .clone()
        });

    match rt.block_on(pm.restart()) {
        Ok(_) => {
            std::thread::sleep(std::time::Duration::from_secs(2));
            rt.block_on(ipc.reconnect()).is_ok()
        }
        Err(_) => false,
    }
}

#[pg_extern]
fn elixir_load_code(module_name: &str, source_code: &str) -> bool {
    let ipc_client = match get_ipc_client() {
        Some(client) => client,
        None => return false,
    };

    let args = serde_json::json!({
        "module": module_name,
        "code": source_code
    });

    let request = Request::new("hot_load_code".to_string(), args);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| {
            tokio::runtime::Runtime::new()
                .expect("Failed to create runtime")
                .handle()
                .clone()
        });

    match rt.block_on(ipc_client.send_request(request)) {
        Ok(response) => response.success,
        Err(_) => false,
    }
}

#[allow(non_snake_case)]
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    // Allocate shared memory for cross-process state
    unsafe {
        use pgrx::pg_sys::*;
        use std::ffi::CString;

        // Request shared memory on first load
        static mut SHM_REQUESTED: bool = false;
        if !SHM_REQUESTED {
            let size = std::mem::size_of::<ElixirSharedState>();
            let name = CString::new("pg_elixir_state").unwrap();

            // Request shared memory allocation
            RequestAddinShmemSpace(size);

            SHM_REQUESTED = true;
        }

        // Initialize shared memory in postmaster or attach in backends
        if IsUnderPostmaster {
            // Backend process - attach to existing shared memory
            let name = CString::new("pg_elixir_state").unwrap();
            let found = Box::new(false);
            let found_ptr = Box::into_raw(found);

            let shmem = ShmemInitStruct(
                name.as_ptr(),
                std::mem::size_of::<ElixirSharedState>(),
                found_ptr
            );

            if !shmem.is_null() {
                SHARED_STATE = Some(&*(shmem as *const ElixirSharedState));
            }

            let _ = Box::from_raw(found_ptr);
        } else {
            // Postmaster - initialize shared memory
            let name = CString::new("pg_elixir_state").unwrap();
            let found = Box::new(false);
            let found_ptr = Box::into_raw(found);

            let shmem = ShmemInitStruct(
                name.as_ptr(),
                std::mem::size_of::<ElixirSharedState>(),
                found_ptr
            );

            if !shmem.is_null() {
                // Initialize the structure
                std::ptr::write(shmem as *mut ElixirSharedState, ElixirSharedState::new());
                SHARED_STATE = Some(&*(shmem as *const ElixirSharedState));
            }

            let _ = Box::from_raw(found_ptr);
        }
    }

    BackgroundWorkerBuilder::new("Elixir Background Worker")
        .set_function("elixir_bgworker_main")
        .set_library("pg_elixir")
        .enable_spi_access()
        .load();

    pgrx::log!("pg_elixir loaded - background worker enabled with shared memory");
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}