defmodule Subscriber do
  use GenServer

  def start_link(),
    do: GenServer.start_link(__MODULE__, self())

  def received_events(server),
    do: GenServer.call(server, :received_events)

  @impl true
  def init(sender),
    do: {:ok, %{sender: sender, received: [], stopped_count: 0}}

  @impl true
  def handle_call(:received_events, _from, state) do
    result =
      state.received
      |> Enum.reverse()
      |> Enum.map(fn e ->
        data = e.event.data
        :erlang.binary_to_term(data)
      end)

    {:reply, result, state}
  end

  def handle_call(
        {:on_event,
         %{event: %{event_type: "Elixir.ExtremeTest.Events.SlowProcessingEventHappened"}} =
           event} = message,
        _from,
        state
      ) do
    data =
      event.event.data
      |> :erlang.binary_to_term()

    :timer.sleep(data.sleep)
    send(state.sender, message)
    {:reply, :ok, %{state | received: [event | state.received]}}
  end

  def handle_call(
        {:on_event,
         %{event: %{event_type: "Elixir.ExtremeTest.Events.StopOnThisOne"}} =
           event} = message,
        _from,
        state
      ) do
    data =
      event.event.data
      |> :erlang.binary_to_term()

    send(state.sender, message)

    if data.times > state.stopped_count do
      {:reply, :stop, %{state | stopped_count: state.stopped_count + 1}}
    else
      {:reply, :ok, %{state | received: [event | state.received]}}
    end
  end

  def handle_call({:on_event, event} = message, _from, state) do
    send(state.sender, message)
    {:reply, :ok, %{state | received: [event | state.received]}}
  end

  def handle_call({:on_event, event, _correlation_id} = message, _from, state) do
    send(state.sender, message)
    {:reply, :ok, %{state | received: [event | state.received]}}
  end

  @impl true
  def handle_info({:extreme, _} = message, state) do
    send(state.sender, message)
    {:noreply, state}
  end

  def handle_info({:extreme, _, _, _} = message, state) do
    send(state.sender, message)
    {:noreply, state}
  end

  def handle_info(:caught_up, state) do
    send(state.sender, :caught_up)
    {:noreply, state}
  end
end
