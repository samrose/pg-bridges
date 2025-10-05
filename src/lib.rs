use pgrx::prelude::*;
use pgrx::bgworkers::BackgroundWorkerBuilder;
use uuid::Uuid;

mod bgworker;
mod ipc;
mod process;
mod protocol;

pub use bgworker::*;
pub use ipc::*;
pub use process::*;
pub use protocol::*;

pgrx::pg_module_magic!();

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

    // Create runtime and connect, then send request
    let rt = tokio::runtime::Runtime::new().expect("Failed to create runtime");

    let result = rt.block_on(async {
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
    let pm = match get_process_manager() {
        Some(pm) => pm,
        None => return format!("{{\"status\": \"not_initialized\"}}"),
    };

    let _ipc = match get_ipc_client() {
        Some(ipc) => ipc,
        None => return format!("{{\"status\": \"ipc_not_initialized\"}}"),
    };

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| {
            tokio::runtime::Runtime::new()
                .expect("Failed to create runtime")
                .handle()
                .clone()
        });

    let is_running = rt.block_on(pm.is_running());
    let memory_usage = rt.block_on(pm.get_memory_usage());

    let health = serde_json::json!({
        "status": if is_running { "healthy" } else { "unhealthy" },
        "process_running": is_running,
        "memory_mb": memory_usage.map(|m| m / (1024 * 1024)),
    });

    serde_json::to_string(&health).unwrap_or_else(|_| "{}".to_string())
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
    BackgroundWorkerBuilder::new("Elixir Background Worker")
        .set_function("elixir_bgworker_main")
        .set_library("pg_elixir")
        .enable_spi_access()
        .load();

    // Note: GUC definitions for pgrx 0.11.x require different syntax
    // These are placeholder - need to be updated for the specific pgrx version
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}