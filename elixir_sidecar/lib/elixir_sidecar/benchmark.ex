defmodule ElixirSidecar.Benchmark do
  @moduledoc """
  Performance benchmarking utilities for the Elixir sidecar.
  """

  require Logger

  def run do
    Logger.info("Starting ElixirSidecar benchmarks...")

    results = %{
      function_registry: benchmark_function_registry(),
      ipc_performance: benchmark_ipc_performance(),
      memory_usage: benchmark_memory_usage(),
      concurrent_requests: benchmark_concurrent_requests()
    }

    Logger.info("Benchmark results: #{inspect(results, pretty: true)}")
    results
  end

  defp benchmark_function_registry do
    Logger.info("Benchmarking function registry performance...")

    # Register test functions
    functions = 1..100 |> Enum.map(fn i ->
      name = "test_function_#{i}"
      fun = fn args -> %{"result" => i, "input" => args} end
      ElixirSidecar.FunctionRegistry.register(name, fun)
      name
    end)

    # Benchmark function calls
    start_time = System.monotonic_time(:microsecond)

    Enum.each(1..1000, fn i ->
      function_name = Enum.at(functions, rem(i, 100))
      ElixirSidecar.FunctionRegistry.call(function_name, %{"test" => i})
    end)

    end_time = System.monotonic_time(:microsecond)
    duration_ms = (end_time - start_time) / 1000

    # Cleanup
    Enum.each(functions, &ElixirSidecar.FunctionRegistry.unregister/1)

    %{
      total_calls: 1000,
      duration_ms: duration_ms,
      calls_per_second: 1000 / (duration_ms / 1000),
      avg_call_time_us: duration_ms * 1000 / 1000
    }
  end

  defp benchmark_ipc_performance do
    Logger.info("Benchmarking IPC performance...")

    socket_path = "/tmp/pg_elixir_benchmark.sock"
    File.rm(socket_path)

    # Start a test server
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {:local, socket_path}])

    server_task = Task.async(fn ->
      benchmark_server_loop(listen_socket, 0)
    end)

    # Give server time to start
    Process.sleep(100)

    # Benchmark client requests
    {:ok, client_socket} = :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: 4])

    start_time = System.monotonic_time(:microsecond)

    Enum.each(1..1000, fn i ->
      request = %{
        "id" => "test_#{i}",
        "function" => "echo",
        "args" => %{"value" => i}
      }

      json = Jason.encode!(request)
      :gen_tcp.send(client_socket, json)

      {:ok, response_json} = :gen_tcp.recv(client_socket, 0, 5000)
      _response = Jason.decode!(response_json)
    end)

    end_time = System.monotonic_time(:microsecond)
    duration_ms = (end_time - start_time) / 1000

    :gen_tcp.close(client_socket)
    :gen_tcp.close(listen_socket)
    Task.shutdown(server_task, :brutal_kill)

    File.rm(socket_path)

    %{
      total_requests: 1000,
      duration_ms: duration_ms,
      requests_per_second: 1000 / (duration_ms / 1000),
      avg_request_time_us: duration_ms * 1000 / 1000
    }
  end

  defp benchmark_server_loop(listen_socket, count) do
    case :gen_tcp.accept(listen_socket, 100) do
      {:ok, client_socket} ->
        handle_benchmark_client(client_socket)
        benchmark_server_loop(listen_socket, count + 1)

      {:error, :timeout} ->
        if count > 0 do
          benchmark_server_loop(listen_socket, count)
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_benchmark_client(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        request = Jason.decode!(data)

        response = %{
          "id" => request["id"],
          "success" => true,
          "result" => request["args"]
        }

        response_json = Jason.encode!(response)
        :gen_tcp.send(socket, response_json)

        handle_benchmark_client(socket)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp benchmark_memory_usage do
    Logger.info("Benchmarking memory usage...")

    initial_memory = :erlang.memory()

    # Create a large number of processes and data structures
    processes = Enum.map(1..1000, fn i ->
      spawn(fn ->
        # Create some data
        data = Enum.map(1..100, fn j -> %{id: i * 100 + j, data: :crypto.strong_rand_bytes(1024)} end)
        Process.sleep(1000)
        # Keep data in scope
        Enum.count(data)
      end)
    end)

    Process.sleep(100)
    peak_memory = :erlang.memory()

    # Wait for processes to finish
    Enum.each(processes, fn pid ->
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2000 -> Process.exit(pid, :kill)
      end
    end)

    Process.sleep(100)
    :erlang.garbage_collect()
    final_memory = :erlang.memory()

    %{
      initial_memory_mb: div(initial_memory[:total], 1024 * 1024),
      peak_memory_mb: div(peak_memory[:total], 1024 * 1024),
      final_memory_mb: div(final_memory[:total], 1024 * 1024),
      memory_growth_mb: div(peak_memory[:total] - initial_memory[:total], 1024 * 1024),
      memory_recovered_mb: div(peak_memory[:total] - final_memory[:total], 1024 * 1024)
    }
  end

  defp benchmark_concurrent_requests do
    Logger.info("Benchmarking concurrent request handling...")

    # Register a test function that takes some time
    ElixirSidecar.FunctionRegistry.register("slow_function", fn %{"delay" => delay} ->
      Process.sleep(delay)
      %{"completed_at" => System.system_time(:millisecond)}
    end)

    concurrency_levels = [1, 10, 50, 100]

    results = Enum.map(concurrency_levels, fn concurrency ->
      start_time = System.monotonic_time(:microsecond)

      tasks = Enum.map(1..concurrency, fn _i ->
        Task.async(fn ->
          ElixirSidecar.FunctionRegistry.call("slow_function", %{"delay" => 50})
        end)
      end)

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await(&1, 10000))

      end_time = System.monotonic_time(:microsecond)
      duration_ms = (end_time - start_time) / 1000

      %{
        concurrency: concurrency,
        duration_ms: duration_ms,
        requests_per_second: concurrency / (duration_ms / 1000)
      }
    end)

    # Cleanup
    ElixirSidecar.FunctionRegistry.unregister("slow_function")

    %{
      concurrency_results: results,
      max_throughput: Enum.max_by(results, & &1.requests_per_second)
    }
  end
end