defmodule Extreme.Connection do
  use GenServer
  alias Extreme.{Configuration, Tcp, RequestManager}
  alias Extreme.ConnectionImpl, as: Impl
  require Logger

  defmodule State do
    defstruct ~w(base_name socket received_data)a
  end

  def start_link(base_name, configuration),
    do: GenServer.start_link(__MODULE__, {base_name, configuration}, name: _name(base_name))

  def push(base_name, message) do
    :ok =
      base_name
      |> _name()
      |> GenServer.cast({:execute, message})
  end

  @impl GenServer
  def init({base_name, configuration}) do
    GenServer.cast(self(), {:connect, configuration, 1})

    state = %State{
      base_name: base_name,
      received_data: ""
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:connect, configuration, attempt}, state) do
    configuration
    |> _connect(attempt)
    |> case do
      {:ok, socket} ->
        Logger.info(fn -> "Successfully connected to EventStore" end)

        :ok =
          configuration
          |> Configuration.get_connection_name()
          |> RequestManager.identify_client(state.base_name)

        {:noreply, %State{state | socket: socket}}

      error ->
        {:stop, error, state}
    end
  end

  def handle_cast({:execute, message}, %State{} = state) do
    case Impl.execute(message, state) do
      :ok -> {:noreply, state}
      other -> {:stop, {:execution_error, other}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, pkg}, %State{socket: socket} = state) do
    {:ok, state} = Impl.receive_package(pkg, state)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, state),
    do: {:stop, :tcp_closed, state}

  @impl GenServer
  def terminate(reason, state) do
    Logger.warning("[Extreme] Connection terminated: #{inspect(reason)}")
    RequestManager.kill_all_subscriptions(state.base_name)
  end

  defp _connect(configuration, attempt) do
    {:ok, host, port} = Configuration.get_node(configuration)
    Tcp.connect(host, port, configuration, attempt)
  end

  def _name(base_name), do: Module.concat(base_name, Connection)
end
