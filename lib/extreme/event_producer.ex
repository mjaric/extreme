defmodule Extreme.EventProducer do
  use GenServer
  require Logger
  alias Extreme.EventProducer.EventBuffer
  alias Extreme.SharedSubscription, as: Shared

  defmodule State do
    defstruct ~w(base_name subscriber ack_timeout buffer_pid)a
  end

  def start_link(base_name, opts) do
    GenServer.start_link(
      __MODULE__,
      {base_name, opts}
    )
  end

  def subscribe(pid),
    do: GenServer.cast(pid, :subscribe)

  def unsubscribe(pid),
    do: GenServer.call(pid, :unsubscribe)

  def on_sync_event(pid, event, timeout),
    do: GenServer.call(pid, {:on_sync_event, event}, timeout)

  def on_async_event(pid, event),
    do: GenServer.cast(pid, {:on_async_event, event})

  def send_to_subscriber(pid, msg),
    do: GenServer.cast(pid, {:send_to_subscriber, msg})

  def subscription_status(pid),
    do: GenServer.call(pid, :subscription_status)

  @impl GenServer
  def init({base_name, opts}) do
    {subscriber, opts} = Keyword.pop!(opts, :subscriber)
    ack_timeout = Keyword.get(opts, :ack_timeout, 5_000)
    {:ok, buffer_pid} = EventBuffer.start_link(base_name, self(), opts)

    state = %State{
      base_name: base_name,
      subscriber: subscriber,
      buffer_pid: buffer_pid,
      ack_timeout: ack_timeout
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:on_sync_event, event}, _from, %State{} = state) do
    Logger.debug("Sending sync event")
    response = Shared.on_event(state.subscriber, event, state.ack_timeout)
    {:reply, response, state}
  end

  def handle_call(:unsubscribe, _from, %State{} = state) do
    response = EventBuffer.unsubscribe(state.buffer_pid)
    {:reply, response, state}
  end

  def handle_call(:subscription_status, _from, %State{} = state) do
    response = EventBuffer.subscription_status(state.buffer_pid)
    {:reply, response, state}
  end

  @impl GenServer
  def handle_cast({:on_async_event, event}, %State{} = state) do
    Logger.debug("Sending async event")

    spawn_link(fn ->
      response = Shared.on_event(state.subscriber, event, state.ack_timeout)
      # Process.sleep(5)
      :ok = EventBuffer.ack(state.buffer_pid, response)
    end)

    {:noreply, state}
  end

  def handle_cast({:send_to_subscriber, msg}, %State{} = state) do
    Logger.debug("Proxing message #{inspect(msg)} to subscriber")
    send(state.subscriber, msg)

    {:noreply, state}
  end

  def handle_cast(:subscribe, %State{} = state) do
    Logger.debug("Starting subscription")
    :ok = EventBuffer.subscribe(state.buffer_pid)

    {:noreply, state}
  end
end
