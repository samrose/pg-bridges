defmodule ElixirSidecar.CodeLoader do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def load_code(module_name, source_code) do
    GenServer.call(__MODULE__, {:load_code, module_name, source_code}, 30_000)
  end

  def list_loaded_modules do
    GenServer.call(__MODULE__, :list_modules)
  end

  @impl true
  def init(_opts) do
    {:ok, %{loaded_modules: %{}}}
  end

  @impl true
  def handle_call({:load_code, module_name, source_code}, _from, state) do
    case compile_and_load(module_name, source_code) do
      {:ok, module} ->
        new_state = put_in(state.loaded_modules[module_name], %{
          module: module,
          loaded_at: System.system_time(:second),
          source: source_code
        })
        Logger.info("Successfully loaded module: #{module_name}")
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to load module #{module_name}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:list_modules, _from, state) do
    modules = Map.keys(state.loaded_modules)
    {:reply, modules, state}
  end

  defp compile_and_load(module_name, source_code) do
    try do
      forms = Code.string_to_quoted!(source_code)

      module_atom = String.to_atom("Elixir." <> module_name)

      {:module, module, _binary, _result} = Module.create(module_atom, forms, __ENV__)

      {:ok, module}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end
end