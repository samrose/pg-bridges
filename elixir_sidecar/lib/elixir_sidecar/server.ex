defmodule ElixirSidecar.Server do
  use GenServer
  require Logger

  @read_timeout 30_000
  @max_message_size 16 * 1024 * 1024

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
        Logger.info("ElixirSidecar listening on #{socket_path}")
        send(self(), :accept)
        {:ok, %{listen_socket: listen_socket, socket_path: socket_path, clients: %{}}}

      {:error, reason} ->
        Logger.error("Failed to listen on socket: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 100) do
      {:ok, client_socket} ->
        :inet.setopts(client_socket, active: :once)
        client_id = :erlang.unique_integer([:positive])

        new_state = put_in(state.clients[client_id], %{
          socket: client_socket,
          connected_at: System.system_time(:second)
        })

        Logger.info("Client #{client_id} connected")
        send(self(), :accept)
        {:noreply, new_state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    client_id = find_client_id(state.clients, socket)

    case Jason.decode(data) do
      {:ok, %{"id" => id, "function" => function, "args" => args} = request} ->
        timeout = Map.get(request, "timeout_ms", @read_timeout)
        Task.Supervisor.start_child(ElixirSidecar.TaskSupervisor, fn ->
          response = handle_request(function, args, timeout)
          send_response(socket, id, response)
        end)

      {:error, reason} ->
        Logger.error("Failed to decode request: #{inspect(reason)}")
    end

    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) do
    client_id = find_client_id(state.clients, socket)
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

  defp find_client_id(clients, socket) do
    Enum.find_value(clients, fn {id, %{socket: s}} ->
      if s == socket, do: id
    end)
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