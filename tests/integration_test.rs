use pg_elixir::*;
use pgrx::prelude::*;
use std::time::Duration;
use tokio::time::sleep;

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use super::*;

    #[pg_test]
    fn test_elixir_call_basic() {
        Spi::run("SELECT elixir_call('echo', '{\"test\": \"value\"}'::jsonb)").unwrap();
    }

    #[pg_test]
    fn test_elixir_call_async() {
        Spi::run("SELECT elixir_call_async('echo', '{\"test\": \"value\"}'::jsonb)").unwrap();
    }

    #[pg_test]
    fn test_elixir_health_check() {
        let result = Spi::get_one::<String>("SELECT status FROM elixir_health() LIMIT 1");
        assert!(result.is_ok());
    }

    #[pg_test]
    fn test_elixir_restart() {
        Spi::run("SELECT elixir_restart()").unwrap();
    }

    #[pg_test]
    fn test_elixir_load_code() {
        let code = r#"
            defmodule TestModule do
              def hello(name) do
                "Hello, #{name}!"
              end
            end
        "#;

        Spi::run(&format!(
            "SELECT elixir_load_code('TestModule', '{}')",
            code.replace('\'', "''")
        ))
        .unwrap();
    }

    #[pg_test]
    async fn test_process_crash_recovery() {
        let process_manager = ProcessManager::new(
            "/usr/local/lib/postgresql/elixir_sidecar".to_string(),
            "/tmp/test_pg_elixir.sock".to_string(),
            2048,
            5,
        );

        process_manager.start().await.unwrap();
        assert!(process_manager.is_running().await);

        process_manager.stop().await.unwrap();
        assert!(!process_manager.is_running().await);

        process_manager.start().await.unwrap();
        assert!(process_manager.is_running().await);

        process_manager.stop().await.unwrap();
    }

    #[pg_test]
    async fn test_memory_limit_enforcement() {
        let process_manager = ProcessManager::new(
            "/usr/local/lib/postgresql/elixir_sidecar".to_string(),
            "/tmp/test_memory_limit.sock".to_string(),
            256,
            5,
        );

        process_manager.start().await.unwrap();
        sleep(Duration::from_secs(2)).await;

        let memory_usage = process_manager.get_memory_usage().await;
        assert!(memory_usage.is_some());

        if let Some(usage) = memory_usage {
            assert!(usage < 256 * 1024 * 1024);
        }

        process_manager.stop().await.unwrap();
    }

    #[pg_test]
    async fn test_restart_backoff() {
        let process_manager = ProcessManager::new(
            "/usr/local/lib/postgresql/elixir_sidecar".to_string(),
            "/tmp/test_backoff.sock".to_string(),
            2048,
            3,
        );

        process_manager.start().await.unwrap();

        for i in 0..3 {
            let result = process_manager.restart().await;
            if i < 3 {
                assert!(result.is_ok());
            }
            sleep(Duration::from_millis(100)).await;
        }

        process_manager.stop().await.unwrap();
    }

    #[pg_test]
    async fn test_ipc_connection() {
        let ipc_client = IpcClient::new("/tmp/test_ipc.sock".to_string());

        let process_manager = ProcessManager::new(
            "/usr/local/lib/postgresql/elixir_sidecar".to_string(),
            "/tmp/test_ipc.sock".to_string(),
            2048,
            5,
        );

        process_manager.start().await.unwrap();
        sleep(Duration::from_secs(1)).await;

        assert!(ipc_client.connect().await.is_ok());

        let request = Request::new("ping".to_string(), serde_json::Value::Null);
        let response = ipc_client.send_request(request).await;
        assert!(response.is_ok());

        process_manager.stop().await.unwrap();
    }

    #[pg_test]
    async fn test_concurrent_requests() {
        let ipc_client = IpcClient::new("/tmp/test_concurrent.sock".to_string());

        let process_manager = ProcessManager::new(
            "/usr/local/lib/postgresql/elixir_sidecar".to_string(),
            "/tmp/test_concurrent.sock".to_string(),
            2048,
            5,
        );

        process_manager.start().await.unwrap();
        sleep(Duration::from_secs(1)).await;

        ipc_client.connect().await.unwrap();

        let mut handles = vec![];

        for i in 0..10 {
            let client_clone = ipc_client.clone();
            let handle = tokio::spawn(async move {
                let request = Request::new(
                    "echo".to_string(),
                    serde_json::json!({"value": i}),
                );
                client_clone.send_request(request).await
            });
            handles.push(handle);
        }

        for handle in handles {
            let result = handle.await.unwrap();
            assert!(result.is_ok());
        }

        process_manager.stop().await.unwrap();
    }

    #[pg_test]
    async fn test_circuit_breaker() {
        let ipc_client = IpcClient::new("/tmp/nonexistent.sock".to_string());

        for _ in 0..6 {
            let request = Request::new("test".to_string(), serde_json::Value::Null);
            let _ = ipc_client.send_request(request).await;
        }

        let request = Request::new("test".to_string(), serde_json::Value::Null);
        let result = ipc_client.send_request(request).await;
        assert!(matches!(result, Err(IpcError::CircuitBreakerOpen)));
    }

    #[pg_test]
    fn test_sql_functions_integration() {
        Spi::run("CREATE EXTENSION IF NOT EXISTS pg_elixir").unwrap();

        let result = Spi::get_one::<i32>("SELECT 1");
        assert_eq!(result.unwrap(), 1);

        Spi::run("SELECT elixir_call('add', '{\"a\": 5, \"b\": 3}'::jsonb)").unwrap();

        let async_id = Spi::get_one::<String>("SELECT elixir_call_async('multiply', '{\"a\": 4, \"b\": 7}'::jsonb)");
        assert!(async_id.is_ok());

        Spi::run("SELECT * FROM elixir_health()").unwrap();
    }
}