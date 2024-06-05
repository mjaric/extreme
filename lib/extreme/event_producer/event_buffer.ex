defmodule Extreme.EventProducer.EventBuffer do
  use GenServer
  require Logger
  alias Extreme.{Subscription, EventProducer}

  defmodule State do
    defstruct ~w(base_name producer_pid subscription_params_fn subscription subscription_ref
      stream ack_timeout buffered_events last_buffered_event_number max_buffered auto_subscribe status)a
  end

  def start_link(base_name, producer_pid, opts),
    do: GenServer.start_link(__MODULE__, {base_name, producer_pid, opts})

  def ack(pid, response),
    do: GenServer.cast(pid, {:ack, response})

  def unsubscribe(pid),
    do: GenServer.call(pid, :unsubscribe)

  @impl GenServer
  def init({base_name, producer_pid, opts}) do
    stream = Keyword.fetch!(opts, :stream)
    from_event_number = Keyword.get(opts, :from_event_number, -1)
    per_page = Keyword.get(opts, :per_page, 100)
    resolve_link_tos = Keyword.get(opts, :resolve_link_tos, true)
    require_master = Keyword.get(opts, :require_master, false)
    ack_timeout = Keyword.get(opts, :ack_timeout, 5_000)

    max_buffered = Keyword.get(opts, :max_buffered, per_page * 2)
    auto_subscribe = Keyword.get(opts, :auto_subscribe, true)

    subscription_params_fn = fn from_event_number ->
      {stream, from_event_number, per_page, resolve_link_tos, require_master, ack_timeout}
    end

    state = %State{
      base_name: base_name,
      producer_pid: producer_pid,
      subscription_params_fn: subscription_params_fn,
      stream: stream,
      ack_timeout: ack_timeout,
      status: :disconnected,
      buffered_events: :queue.new(),
      last_buffered_event_number: from_event_number,
      max_buffered: max_buffered,
      auto_subscribe: auto_subscribe
    }

    Logger.debug("Initialized event buffer #{inspect(state)}")

    if auto_subscribe,
      do: GenServer.cast(self(), :subscribe)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:subscribe, state) do
    Logger.debug(
      "Subscribing to #{state.stream} starting with #{state.last_buffered_event_number}"
    )

    {:ok, subscription} =
      Extreme.RequestManager.read_and_stay_subscribed(
        state.base_name,
        self(),
        state.subscription_params_fn.(state.last_buffered_event_number + 1)
      )

    ref = Process.monitor(subscription)

    {:noreply,
     %{
       state
       | subscription: subscription,
         subscription_ref: ref,
         status: :catching_up
     }}
  end

  def handle_cast({:ack, :ok}, %State{} = state) do
    {{:value, _}, buffered_events} = :queue.out(state.buffered_events)
    Logger.debug("Event acked")

    # push new buffered event if there is one
    buffered_events
    |> :queue.out()
    |> case do
      {{:value, event}, _} ->
        :ok = EventProducer.on_async_event(state.producer_pid, event)

      _ ->
        :ok
    end

    # start subscription if status is :paused and we don't have buffered events
    # I wanted to make it if it was < max/2 but applying backpresure would be hard
    # in cahtching up mode while we still have buffered events
    if state.status == :paused and :queue.len(buffered_events) == 0 do
      Logger.info("Resuming subscription on #{state.stream}")
      :ok = GenServer.cast(self(), :subscribe)
    end

    {:noreply, %State{state | buffered_events: buffered_events}}
  end

  def handle_cast({:ack, :stop}, %State{} = state) do
    Logger.debug("Received `:stop` response from subscriber")
    :ok = Subscription.unsubscribe(state.subscription)
    {:noreply, %State{state | subscription: nil, subscription_ref: nil, status: :paused}}
  end

  def handle_call(:unsubscribe, _from, %State{} = state) do
    Logger.debug("Received `:unsubscribe` request")
    response = Subscription.unsubscribe(state.subscription)
    state = %State{state | subscription: nil, subscription_ref: nil, status: :paused}

    {:reply, response, state}
  end

  @impl GenServer
  def handle_call({:on_event, event}, _from, %State{status: :catching_up} = state) do
    Logger.debug("Got event while catching up")
    _sync_push_event_to_producer(event, state)
  end

  def handle_call({:on_event, event}, _from, %State{status: :live} = state) do
    Logger.debug("Got event in live mode")

    buffered_events = :queue.in(event, state.buffered_events)
    buffer_size = :queue.len(buffered_events)
    {:ok, event_number} = _get_event_number(event)

    if buffer_size == 1,
      do: :ok = EventProducer.on_async_event(state.producer_pid, event)

    response =
      if buffer_size >= state.max_buffered do
        Logger.warning(
          "Event buffer is full (#{inspect(buffer_size)}). Turning off subscription on #{state.stream}"
        )

        :stop
      else
        :ok
      end

    {:reply, response,
     %State{state | buffered_events: buffered_events, last_buffered_event_number: event_number}}
  end

  def handle_call({:on_event, _event}, _from, %State{} = state) do
    Logger.warning("We shouldn't get event in #{inspect(state.status)} status")
    {:reply, :stop, state}
  end

  @impl GenServer
  def handle_info(:caught_up, %State{subscription: subscription} = state)
      when not is_nil(subscription) do
    Logger.debug("Caught up now")
    :ok = EventProducer.send_to_subscriber(state.producer_pid, :caught_up)
    {:noreply, %State{state | status: :live}}
  end

  def handle_info(
        {:DOWN, ref, :process, subscription, {:shutdown, reason}},
        %State{subscription: subscription, subscription_ref: ref} = state
      )
      when reason in [:processing_of_event_requested_stopping_subscription, :unsubscribed] do
    Logger.debug("Subscription went down as requested")
    {:noreply, %State{state | subscription: nil, subscription_ref: nil, status: :paused}}
  end

  def handle_info(
        {:DOWN, _ref, :process, _subscription, {:shutdown, _}},
        %State{subscription: nil, subscription_ref: nil, status: :paused} = state
      ) do
    # we are already aware of that
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _subscription, reason}, %State{} = state) do
    Logger.warning("Subscription unexpectedly went down: #{inspect(reason)}")
    {:noreply, %State{state | subscription: nil, subscription_ref: nil, status: :paused}}
  end

  def handle_info(msg, %State{} = state) do
    :ok = EventProducer.send_to_subscriber(state.producer_pid, msg)
    {:noreply, state}
  end

  defp _sync_push_event_to_producer(event, %State{} = state) do
    state.producer_pid
    |> EventProducer.on_sync_event(event, state.ack_timeout)
    |> case do
      :ok ->
        {:ok, event_number} = _get_event_number(event)
        {:reply, :ok, %State{state | last_buffered_event_number: event_number}}

      :stop ->
        {:reply, :stop, %State{state | status: :paused}}
    end
  end

  defp _get_event_number(%{link: %{event_number: event_number}}),
    do: {:ok, event_number}

  defp _get_event_number(%{link: nil, event: %{event_number: event_number}}),
    do: {:ok, event_number}
end
