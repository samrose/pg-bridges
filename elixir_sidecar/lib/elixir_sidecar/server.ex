defmodule ElixirSidecar.Server do
  use GenServer
  require Logger

  @read_timeout 30_000
  @num_acceptors 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    Process.flag(:trap_exit, true)

    File.rm(socket_path)
    File.mkdir_p!(Path.dirname(socket_path))

    case :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {:local, socket_path}]) do
      {:ok, listen_socket} ->
        Logger.info("ElixirSidecar listening on #{socket_path} with #{@num_acceptors} acceptors")

        # Start multiple acceptor processes for concurrent connection handling
        for _ <- 1..@num_acceptors do
          spawn_acceptor(listen_socket)
        end

        {:ok, %{listen_socket: listen_socket, socket_path: socket_path, clients: %{}}}

      {:error, reason} ->
        Logger.error("Failed to listen on socket: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp spawn_acceptor(listen_socket) do
    server_pid = self()

    spawn_link(fn ->
      acceptor_loop(listen_socket, server_pid)
    end)
  end

  defp acceptor_loop(listen_socket, server_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Register client with the server
        client_id = :erlang.unique_integer([:positive])
        send(server_pid, {:client_connected, client_id, client_socket})

        # Handle this client in a separate process
        spawn_link(fn ->
          handle_client(client_socket, client_id, server_pid)
        end)

        # Continue accepting more connections
        acceptor_loop(listen_socket, server_pid)

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        # Restart acceptor on error
        Process.sleep(100)
        acceptor_loop(listen_socket, server_pid)
    end
  end

  defp handle_client(socket, client_id, server_pid) do
    :inet.setopts(socket, active: :once)
    client_loop(socket, client_id, server_pid)
  end

  defp client_loop(socket, client_id, server_pid) do
    receive do
      {:tcp, ^socket, data} ->
        case Jason.decode(data) do
          {:ok, %{"id" => id, "function" => function, "args" => args} = request} ->
            timeout = Map.get(request, "timeout_ms", @read_timeout)

            # Process request asynchronously
            Task.Supervisor.start_child(ElixirSidecar.TaskSupervisor, fn ->
              response = handle_request(function, args, timeout)
              send_response(socket, id, response)
            end)

          {:error, reason} ->
            Logger.error("Failed to decode request: #{inspect(reason)}")
        end

        :inet.setopts(socket, active: :once)
        client_loop(socket, client_id, server_pid)

      {:tcp_closed, ^socket} ->
        send(server_pid, {:client_disconnected, client_id, socket})
        :ok

      {:tcp_error, ^socket, reason} ->
        Logger.error("Client #{client_id} socket error: #{inspect(reason)}")
        send(server_pid, {:client_disconnected, client_id, socket})
        :ok
    end
  end

  @impl true
  def handle_info({:client_connected, client_id, socket}, state) do
    new_state = put_in(state.clients[client_id], %{
      socket: socket,
      connected_at: System.system_time(:second)
    })

    Logger.info("Client #{client_id} connected")
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:client_disconnected, client_id, _socket}, state) do
    Logger.info("Client #{client_id} disconnected")
    new_clients = Map.delete(state.clients, client_id)
    {:noreply, %{state | clients: new_clients}}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.error("Process exited: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Server terminating: #{inspect(reason)}")
    if Map.has_key?(state, :listen_socket) do
      :gen_tcp.close(state.listen_socket)
    end
    if Map.has_key?(state, :socket_path) do
      File.rm(state.socket_path)
    end
    :ok
  end

  defp handle_request("ping", _args, _timeout) do
    {:ok, "pong"}
  end

  defp handle_request("hot_load_code", %{"module" => module, "code" => code}, _timeout) do
    case ElixirSidecar.CodeLoader.load_code(module, code) do
      :ok -> {:ok, %{"status" => "loaded", "module" => module}}
      {:error, reason} -> {:error, "Failed to load code: #{inspect(reason)}"}
    end
  end

  defp handle_request(function_name, args, timeout) do
    case ElixirSidecar.FunctionRegistry.call(function_name, args, timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Function call failed: #{inspect(reason)}"}
    end
  end

  defp send_response(socket, id, response) do
    response_map = case response do
      {:ok, result} ->
        %{
          "id" => id,
          "success" => true,
          "result" => result
        }

      {:error, error} ->
        %{
          "id" => id,
          "success" => false,
          "result" => nil,
          "error" => to_string(error)
        }
    end

    case Jason.encode(response_map) do
      {:ok, json} ->
        :gen_tcp.send(socket, json)

      {:error, reason} ->
        Logger.error("Failed to encode response: #{inspect(reason)}")
        error_response = %{
          "id" => id,
          "success" => false,
          "result" => nil,
          "error" => "Internal encoding error"
        }
        {:ok, error_json} = Jason.encode(error_response)
        :gen_tcp.send(socket, error_json)
    end
  end
end