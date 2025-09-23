defmodule ElixirSidecar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    socket_path = System.get_env("ELIXIR_SOCKET_PATH", "/tmp/pg_elixir.sock")

    children = [
      {ElixirSidecar.Server, socket_path: socket_path},
      {ElixirSidecar.FunctionRegistry, []},
      {ElixirSidecar.CodeLoader, []},
      {Task.Supervisor, name: ElixirSidecar.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: ElixirSidecar.Supervisor]
    Supervisor.start_link(children, opts)
  end
end