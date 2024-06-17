defmodule Extreme.PersistentSubscriptionTest do
  use ExUnit.Case, async: false

  alias ExtremeTest.{Events, Helpers}
  alias Extreme.PersistentSubscription

  defmodule Subscriber do
    use GenServer

    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end

    def init(args) do
      {:ok, subscription_pid} =
        TestConn.connect_to_persistent_subscription(
          self(),
          args.stream,
          args.group,
          args.allowed_in_flight_messages
        )

      {:ok, Map.put(args, :subscription_pid, subscription_pid)}
    end

    def handle_cast({:on_event, _event, _correlation_id} = message, state) do
      send(state.subscriber, message)

      {:noreply, state}
    end

    def handle_call(:unsubscribe, _from, state) do
      :unsubscribed = TestConn.unsubscribe(state.subscription_pid)

      {:reply, :ok, state}
    end

    def handle_info({:ack, event_or_event_ids, correlation_id}, state) do
      :ok = PersistentSubscription.ack(state.subscription_pid, event_or_event_ids, correlation_id)

      {:noreply, state}
    end

    def handle_info({:nack, event_or_event_ids, correlation_id, action}, state) do
      :ok =
        PersistentSubscription.nack(
          state.subscription_pid,
          event_or_event_ids,
          correlation_id,
          action
        )

      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}
  end

  describe "given a persisent subscription exists for a stream with events" do
    setup do
      stream = Helpers.random_stream_name()
      group = random_subscription_group_name()
      events = random_events()

      {:ok, %{result: :success}} = Helpers.write_events(stream, events) |> TestConn.execute()

      {:ok, %{result: :success}} =
        Helpers.create_persistent_subscription(stream, group) |> TestConn.execute()

      on_exit(fn ->
        Helpers.delete_persistent_subscription(stream, group) |> TestConn.execute()
        Helpers.delete_stream(stream, false) |> TestConn.execute()
      end)

      [
        stream: stream,
        group: group,
        events: events
      ]
    end

    test """
         when subscribing to a persistent subscription
         then the subscriber receives the events in stream
         """,
         c do
      {:ok, subscriber} =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, length(c.events))
        |> Map.put(:subscriber, self())
        |> Subscriber.start_link()

      for n <- 1..length(c.events) do
        assert_receive {:on_event, received_event, _correlation_id}
        assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, n - 1)
      end

      :ok = GenServer.stop(subscriber)
    end

    test """
         when attempting to acknowledge an event by providing the full received event
         then the acknowledgement is accepted
         """,
         c do
      {:ok, subscriber} =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, 1)
        |> Map.put(:subscriber, self())
        |> Subscriber.start_link()

      for n <- 1..length(c.events) do
        assert_receive {:on_event, received_event, correlation_id}
        assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, n - 1)
        send(subscriber, {:ack, received_event, correlation_id})
      end

      :ok = GenServer.stop(subscriber)
    end

    test """
         when attempting to acknowledge an event by providing only the event IDs
         then the acknowledgement is accepted
         """,
         c do
      {:ok, subscriber} =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, 1)
        |> Map.put(:subscriber, self())
        |> Subscriber.start_link()

      for n <- 1..length(c.events) do
        assert_receive {:on_event, received_event, correlation_id}
        assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, n - 1)
        send(subscriber, {:ack, received_event.event.event_id, correlation_id})
      end

      :ok = GenServer.stop(subscriber)
    end

    test """
         when reconnecting to an existing persistent subscription
         then the remaining events should be delivered
         then the positively acknowledged events should not be redelivered
         """,
         c do
      opts =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, 1)
        |> Map.put(:subscriber, self())

      {:ok, subscriber} = Subscriber.start_link(opts)

      Process.unlink(subscriber)

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 0)
      send(subscriber, {:ack, received_event, correlation_id})

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 1)
      send(subscriber, {:ack, received_event, correlation_id})

      assert_receive {:on_event, received_event, _correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 2)

      # N.B. the event is _not_ acked

      true = Process.unlink(subscriber)
      subscriber_ref = Process.monitor(subscriber)
      :ok = GenServer.call(subscriber, :unsubscribe)
      :ok = GenServer.stop(subscriber)

      assert_receive {:DOWN, ^subscriber_ref, _, _, _}

      {:ok, subscriber} = Subscriber.start_link(opts)

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 2)
      send(subscriber, {:ack, received_event.event.event_id, correlation_id})

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 3)
      send(subscriber, {:ack, received_event.event.event_id, correlation_id})

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 4)
      send(subscriber, {:ack, received_event.event.event_id, correlation_id})

      :ok = GenServer.stop(subscriber)
    end

    test """
         when events are 'nack'-ed
         then the 'nack'-ed events are re-delivered
         """,
         c do
      {:ok, subscriber} =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, 1)
        |> Map.put(:subscriber, self())
        |> Subscriber.start_link()

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 0)
      send(subscriber, {:nack, received_event.event.event_id, correlation_id, :retry})

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 0)
      send(subscriber, {:ack, received_event.event.event_id, correlation_id})

      :ok = GenServer.stop(subscriber)
    end

    test """
         when events are 'nack'-ed with 'park' action
         then the 'nack'-ed events are not re-delivered
         """,
         c do
      {:ok, subscriber} =
        c
        |> Map.take([:stream, :group])
        |> Map.put(:allowed_in_flight_messages, 1)
        |> Map.put(:subscriber, self())
        |> Subscriber.start_link()

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 0)
      send(subscriber, {:nack, received_event.event.event_id, correlation_id, :park})

      assert_receive {:on_event, received_event, correlation_id}
      assert :erlang.binary_to_term(received_event.event.data) == Enum.at(c.events, 1)
      send(subscriber, {:ack, received_event.event.event_id, correlation_id})

      :ok = GenServer.stop(subscriber)
    end
  end

  defp random_subscription_group_name, do: "subscription-#{UUID.uuid4()}"

  defp random_events do
    for n <- 1..5 do
      %Events.PersonCreated{name: n}
    end
  end
end
