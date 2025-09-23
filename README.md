# pg_elixir - PostgreSQL Extension for Elixir/BEAM Integration

A production-ready PostgreSQL extension that runs an Elixir/BEAM application as a background worker sidecar, enabling seamless integration between PostgreSQL and Elixir.

## Features

- 🚀 **Background Worker Architecture**: Runs Elixir as a managed PostgreSQL background worker
- 🔌 **Unix Domain Socket IPC**: High-performance communication via Unix sockets
- 🔄 **Automatic Process Management**: Crash recovery with exponential backoff
- 🛡️ **Resource Limits**: Memory and file descriptor limits enforced
- ⚡ **Async Operations**: Support for both synchronous and asynchronous function calls
- 🔥 **Hot Code Loading**: Load new Elixir code without restarting
- 📊 **Health Monitoring**: Built-in health checks and metrics
- 🔧 **Circuit Breaker**: Automatic failure protection

## Architecture

```
┌─────────────────────────────────────┐
│         PostgreSQL Server           │
│                                     │
│  ┌─────────────────────────────┐   │
│  │     pg_elixir Extension     │   │
│  │                             │   │
│  │  ┌──────────────────────┐  │   │
│  │  │  Background Worker   │  │   │
│  │  └──────────┬───────────┘  │   │
│  │             │               │   │
│  │  ┌──────────▼───────────┐  │   │
│  │  │    IPC Client       │  │   │
│  │  └──────────┬───────────┘  │   │
│  └─────────────┼───────────────┘   │
│                │                    │
└────────────────┼────────────────────┘
                 │
                 │ Unix Socket
                 │ /tmp/pg_elixir.sock
                 │
┌────────────────▼────────────────────┐
│       Elixir/BEAM Sidecar          │
│                                     │
│  ┌─────────────────────────────┐   │
│  │      Socket Server          │   │
│  ├─────────────────────────────┤   │
│  │    Function Registry        │   │
│  ├─────────────────────────────┤   │
│  │      Code Loader           │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

## Prerequisites

- PostgreSQL 12-16
- Rust 1.70+
- Elixir 1.14+
- pgrx CLI tool

## Installation

### 1. Install pgrx

```bash
cargo install --locked cargo-pgrx
cargo pgrx init
```

### 2. Build the Elixir Sidecar

```bash
cd elixir_sidecar
mix deps.get
MIX_ENV=prod mix release elixir_sidecar
```

The Burrito-packaged executable will be created at `_build/prod/rel/elixir_sidecar/elixir_sidecar`.

### 3. Build and Install the PostgreSQL Extension

```bash
# From the project root
cargo pgrx install --release
```

### 4. Configure PostgreSQL

Add to `postgresql.conf`:

```conf
shared_preload_libraries = 'pg_elixir'
elixir.enabled = true
elixir.executable_path = '/path/to/elixir_sidecar'
elixir.socket_path = '/tmp/pg_elixir.sock'
elixir.request_timeout_ms = 30000
elixir.max_restarts = 5
elixir.memory_limit_mb = 2048
```

### 5. Create the Extension

```sql
CREATE EXTENSION pg_elixir;
```

## Usage

### Basic Function Calls

```sql
-- Synchronous call
SELECT elixir_call('echo', '{"message": "Hello from PostgreSQL!"}'::jsonb);

-- Mathematical operations
SELECT elixir_call('add', '{"a": 5, "b": 3}'::jsonb);
-- Returns: {"result": 8}

SELECT elixir_call('multiply', '{"a": 4, "b": 7}'::jsonb);
-- Returns: {"result": 28}
```

### Asynchronous Operations

```sql
-- Start an async operation
SELECT elixir_call_async('long_running_task', '{"data": "process this"}'::jsonb) AS request_id;

-- Check the result later
SELECT elixir_get_result('550e8400-e29b-41d4-a716-446655440000'::uuid);
```

### Health Monitoring

```sql
-- Check system health
SELECT * FROM elixir_health();

-- Output:
-- status           | uptime_seconds | memory_mb | request_count
-- -----------------+----------------+-----------+---------------
-- healthy          | 3600           | 256       | 1523
```

### Process Management

```sql
-- Restart the Elixir process
SELECT elixir_restart();

-- Returns: true on success
```

### Hot Code Loading

```sql
-- Load new Elixir code dynamically
SELECT elixir_load_code('MyModule', '
  defmodule MyModule do
    def greet(name) do
      "Hello, #{name}!"
    end
  end
');
```

## Custom Functions

Register custom functions in the Elixir sidecar by modifying `elixir_sidecar/lib/elixir_sidecar/function_registry.ex`:

```elixir
# Register a custom function
ElixirSidecar.FunctionRegistry.register("my_function", fn args ->
  # Your custom logic here
  %{"result" => "processed"}
end)
```

## Configuration Reference

| Parameter | Description | Default | Range |
|-----------|-------------|---------|--------|
| `elixir.enabled` | Enable/disable the extension | `true` | boolean |
| `elixir.executable_path` | Path to Elixir sidecar | `/usr/local/lib/postgresql/elixir_sidecar` | text |
| `elixir.socket_path` | Unix socket path | `/tmp/pg_elixir.sock` | text |
| `elixir.request_timeout_ms` | Request timeout | `30000` | 1000-300000 |
| `elixir.max_restarts` | Max restarts in 60s | `5` | 0-100 |
| `elixir.memory_limit_mb` | Memory limit for BEAM | `2048` | 256-16384 |

## Development

### Running Tests

```bash
# Rust tests
cargo pgrx test

# Elixir tests
cd elixir_sidecar
mix test
```

### Building for Different PostgreSQL Versions

```bash
cargo pgrx install --pg12
cargo pgrx install --pg13
cargo pgrx install --pg14
cargo pgrx install --pg15
cargo pgrx install --pg16
```

## Performance Considerations

- **Connection Pooling**: The extension maintains a persistent connection to the Elixir sidecar
- **Message Size**: Maximum message size is 16MB
- **Concurrency**: Supports concurrent requests with automatic queueing
- **Circuit Breaker**: After 5 consecutive failures, requests are rejected for 30 seconds

## Security

- The extension requires superuser privileges to install
- Resource limits are enforced via `setrlimit`
- All inputs are validated before processing
- The Unix socket is created with restricted permissions

## Troubleshooting

### Elixir Process Won't Start

1. Check the executable path is correct
2. Verify file permissions
3. Check PostgreSQL logs for error messages
4. Ensure the socket directory exists and is writable

### Connection Timeouts

1. Increase `elixir.request_timeout_ms`
2. Check if the Elixir process is running: `SELECT * FROM elixir_health()`
3. Verify the socket path is correct

### High Memory Usage

1. Reduce `elixir.memory_limit_mb`
2. Monitor with: `SELECT memory_mb FROM elixir_health()`
3. Check for memory leaks in custom functions

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

## Support

For issues and questions:
- GitHub Issues: [pg_elixir/issues](https://github.com/yourusername/pg_elixir/issues)
- Documentation: [pg_elixir/wiki](https://github.com/yourusername/pg_elixir/wiki)