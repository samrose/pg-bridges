defmodule ElixirSidecar.FunctionRegistry do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(name, fun) when is_function(fun) do
    GenServer.call(__MODULE__, {:register, name, fun})
  end

  def unregister(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  def call(name, args, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:call, name, args, timeout}, timeout + 1000)
  end

  def list_functions do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(_opts) do
    {:ok, %{functions: %{}, stats: %{}}}
  end

  @impl true
  def handle_call({:register, name, fun}, _from, state) do
    new_state = put_in(state.functions[name], fun)
    Logger.info("Registered function: #{name}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    new_state = Map.delete(state.functions, name)
    Logger.info("Unregistered function: #{name}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:call, name, args, timeout}, _from, state) do
    case Map.get(state.functions, name) do
      nil ->
        # Register default functions directly in state instead of calling ourselves
        new_state = register_default_functions_in_state(state)

        case Map.get(new_state.functions, name) do
          nil ->
            {:reply, {:error, "Function not found: #{name}"}, new_state}

          fun ->
            execute_function(fun, args, timeout, new_state)
        end

      fun ->
        execute_function(fun, args, timeout, state)
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    functions = Map.keys(state.functions)
    {:reply, functions, state}
  end

  defp execute_function(fun, args, timeout, state) do
    task = Task.async(fn ->
      try do
        result = apply(fun, [args])
        {:ok, result}
      rescue
        e ->
          Logger.error("Function execution error: #{inspect(e)}")
          {:error, Exception.message(e)}
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:reply, result, update_stats(state, :success)}

      nil ->
        Logger.error("Function execution timeout")
        {:reply, {:error, "Execution timeout"}, update_stats(state, :timeout)}

      {:exit, reason} ->
        Logger.error("Function execution failed: #{inspect(reason)}")
        {:reply, {:error, "Execution failed"}, update_stats(state, :error)}
    end
  end

  defp update_stats(state, result) do
    stats = Map.update(state.stats, result, 1, &(&1 + 1))
    %{state | stats: stats}
  end

  defp register_default_functions_in_state(state) do
    functions = %{
      "echo" => fn args -> args end,
      "add" => fn %{"a" => a, "b" => b} -> a + b end,
      "multiply" => fn %{"a" => a, "b" => b} -> a * b end,
      "concat" => fn %{"strings" => strings} when is_list(strings) ->
        Enum.join(strings, "")
      end,
      "uppercase" => fn %{"text" => text} ->
        String.upcase(text)
      end,
      "system_info" => fn _ ->
        %{
          "elixir_version" => System.version(),
          "otp_release" => System.otp_release(),
          "system_time" => System.system_time(:second),
          "process_count" => length(Process.list()),
          "memory" => :erlang.memory() |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
        }
      end
    }

    %{state | functions: Map.merge(state.functions, functions)}
  end
end