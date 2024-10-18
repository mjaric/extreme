defmodule Extreme.PersistentSubscription do
  @moduledoc """
  An asynchronous subscription strategy.

  Other subscription methods require stream positions to be persisted by the
  client (e.g. in `:dets` or PostgreSQL). Persistent Subscription is a
  subscription strategy in which details about backpressure, buffer sizes, and
  stream positions are all held by the EventStore (server).

  In a persistent subscription, all communication is asynchronous. When an
  event is received and processed, it must be acknowledged as processed by
  `ack/3` in order to be considered by the server as processed. The server
  stores knowledge of which events have been processed by means of checkpoints,
  so listeners which use persistent subscriptions do not store stream positions
  themselves.

  The system of `ack/3`s and `nack/5`s allows listeners to handle events in
  unconventional ways:

  * concurrent processing: events may be handled by multiple processors at the
    same time.
  * out of order processing: events may be handled in any order.
  * retry: events which are `nack/5`-ed with the `:retry` action, and events
    which do not receive acknowledgement via `ack/3` are retried.
  * message parking: if an event is not acknowledged and reaches its maximum
    retry count, the message is parked in a parked messages queue. This
    prevents head-of-line blocking typical of other subscription patterns.
  * competing consumers: multiple consumers may process events without
    collaboration or gossip between the consumers themselves.

  Persistent subscriptions are started with
  `c:Extreme.connect_to_persistent_subscription/4` expect a `cast` of each event
  in the form of `{:on_event, event, correlation_id}`

  A Persistent Subscription must exist before it can be connected to.
  Persistent Subscriptions can be created by sending the
  `Extreme.Messages.CreatePersistentSubscription` message via
  `c:Extreme.execute/3`, by the HTTP API, or in the EventStore dashboard.

  ## Example

  ```elixir
  defmodule MyPersistentListener do
    use GenServer

    alias Extreme.PersistentSubscription

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      {:ok, opts}
    end

    def subscribe(listener_proc), do: GenServer.cast(listener_proc, :subscribe)

    def handle_cast(:subscribe, state) do
      {:ok, subscription_pid} =
        MyExtremeClientModule.connect_to_persistent_subscription(
          self(),
          opts.stream,
          opts.group,
          opts.allowed_in_flight_messages
        )

      {:noreply, Map.put(state, :subscription_pid, subscription_pid)}
    end

    def handle_cast({:on_event, event, correlation_id}, state) do
      # .. do the real processing here ..

      :ok = PersistentSubscription.ack(state.subscription_pid, event, correlation_id)

      {:noreply, state}
    end

    def handle_call(:unsubscribe, _from, state) do
      :ok = MyExtremeClientModule.unsubscribe(state.subscription_pid)

      {:reply, :ok, state}
    end

    def handle_info(_, state), do: {:noreply, state}
  end
  ```
  """

  use GenServer
  require Logger
  alias Extreme.SharedSubscription, as: Shared
  alias Extreme.RequestManager
  alias Extreme.Messages, as: Msg

  defmodule State do
    @moduledoc false

    defstruct ~w(
      base_name
      correlation_id
      subscriber
      stream
      group
      allowed_in_flight_messages
      status
      subscription_id
    )a
  end

  @typedoc """
  An event received from a persistent subscription.
  """
  @type event() :: %Extreme.Messages.ResolvedIndexedEvent{}
  @typedoc """
  An event ID.

  Either from the `:link` or `:event`, depending on if the event is from a
  projection stream or a normal stream (respectively).
  """
  @type event_id() :: binary()

  @doc false
  def start_link(
        base_name,
        correlation_id,
        subscriber,
        stream,
        group,
        allowed_in_flight_messages
      ) do
    GenServer.start_link(
      __MODULE__,
      {base_name, correlation_id, subscriber, stream, group, allowed_in_flight_messages}
    )
  end

  @doc """
  Acknowledges that an event or set of events have been successfully processed.

  `ack/3` takes any of the following for event ID:

  * a full event, as given in the `{:on_event, event, correlation_id}` cast
  * the `event_id` of an event (either from its `:link` or `:event`, depending
    on if the event comes from a projection or a normal stream, respectively)
  * a list of either sort

  `correlation_id` comes from the `:on_event` cast.

  ## Example

      def handle_cast({:on_event, event, correlation_id}, state) do
        # .. do some processing ..

        # when the processing completes successfully:
        :ok = Extreme.PersistentSubscription.ack(state.subscription_pid, event, correlation_id)

        {:noreply, state}
      end
  """
  @spec ack(pid(), event() | event_id() | [event() | event_id()], binary()) :: :ok
  def ack(subscription, event, correlation_id) when is_map(event) or is_binary(event) do
    ack(subscription, [event], correlation_id)
  end

  def ack(subscription, events, correlation_id) when is_list(events) do
    GenServer.cast(subscription, {:ack, events, correlation_id})
  end

  @doc """
  Acknowledges that an event or set of events could not be handled.

  See `ack/3` for information on `event` and `correlation_id`.

  `action` can be any of the following

  * `:unknown`
  * `:park`
  * `:retry`
  * `:skip`
  * `:stop`

  The `:park` action sets aside the event in the Parked Messages queue, which
  may be replayed via [the HTTP
  API](https://eventstore.com/docs/http-api/competing-consumers/index.html#replaying-parked-messages)
  or by button click in the EventStore Persistent Subscriptions dashboard.

  When an event reaches the max retry count configured by the
  `:max_retry_count` field in `Extreme.Messages.CreatePersistentSubscription`,
  the event is parked.

  ## Example

      def handle_cast({:on_event, event, correlation_id}, state) do
        # .. do some processing ..

        # in the case that the processing fails and should be retried:
        :ok = Extreme.PersistentSubscription.nack(state.subscription_pid, event, correlation_id, :retry)

        {:noreply, state}
      end
  """
  @spec nack(
          pid(),
          event() | event_id() | [event() | event_id()],
          binary(),
          :unknown | :park | :retry | :skip | :stop,
          String.t()
        ) :: :ok
  def nack(subscription, event, correlation_id, action, message \\ "")

  def nack(subscription, event, correlation_id, action, message)
      when is_map(event) or is_binary(event) do
    nack(subscription, [event], correlation_id, action, message)
  end

  def nack(subscription, events, correlation_id, action, message) when is_list(events) do
    GenServer.cast(subscription, {:nack, events, correlation_id, action, message})
  end

  @doc false
  @impl GenServer
  def init({base_name, correlation_id, subscriber, stream, group, allowed_in_flight_messages}) do
    state = %State{
      base_name: base_name,
      correlation_id: correlation_id,
      subscriber: subscriber,
      stream: stream,
      group: group,
      allowed_in_flight_messages: allowed_in_flight_messages,
      status: :initialized
    }

    GenServer.cast(self(), :subscribe)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:unsubscribe, state) do
    :ok = Shared.unsubscribe(state)
    {:noreply, state}
  end

  def handle_cast(:subscribe, state) do
    Msg.ConnectToPersistentSubscription.new(
      subscription_id: state.group,
      event_stream_id: state.stream,
      allowed_in_flight_messages: state.allowed_in_flight_messages
    )
    |> cast_request_manager(state.base_name, state.correlation_id)

    {:noreply, state}
  end

  def handle_cast({:process_push, fun}, state) do
    Shared.process_push(fun, state)
  end

  def handle_cast({:ack, events, correlation_id}, state) do
    Msg.PersistentSubscriptionAckEvents.new(
      subscription_id: state.subscription_id,
      processed_event_ids: event_ids(events)
    )
    |> cast_request_manager(state.base_name, correlation_id)

    {:noreply, state}
  end

  def handle_cast({:nack, events, correlation_id, action, message}, state) do
    Msg.PersistentSubscriptionNakEvents.new(
      subscription_id: state.subscription_id,
      processed_event_ids: event_ids(events),
      action: action,
      message: message
    )
    |> cast_request_manager(state.base_name, correlation_id)

    {:noreply, state}
  end

  defp cast_request_manager(message, base_name, correlation_id) do
    base_name
    |> RequestManager._name()
    |> GenServer.cast({:execute, correlation_id, message})
  end

  defp event_ids(events) when is_list(events) do
    Enum.map(events, &event_id/1)
  end

  defp event_id(event_id) when is_binary(event_id), do: event_id

  defp event_id(%Msg.ResolvedIndexedEvent{link: %Msg.EventRecord{event_id: event_id}}),
    do: event_id

  defp event_id(%Msg.ResolvedIndexedEvent{event: %Msg.EventRecord{event_id: event_id}}),
    do: event_id
end
