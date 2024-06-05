defmodule ExtremeSubscriptionsTest do
  use ExUnit.Case, async: false
  alias ExtremeTest.Helpers
  alias ExtremeTest.Events, as: Event
  alias Extreme.Messages, as: ExMsg
  require Logger

  defmodule Subscriber do
    use GenServer

    def start_link(),
      do: GenServer.start_link(__MODULE__, self())

    def received_events(server),
      do: GenServer.call(server, :received_events)

    @impl true
    def init(sender),
      do: {:ok, %{sender: sender, received: []}}

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

  describe "subscribe_to/3" do
    test "subscription to existing stream is success" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # :caught_up is not received on subscription without previous read
      refute_receive :caught_up

      # write more events after subscription
      num_additional_events = 1000

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert rest events have arrived
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if only new events came in correct order.
      assert Subscriber.received_events(subscriber) == events2

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "subscription to non existing stream is success" do
      # subscribe to stream
      stream = Helpers.random_stream_name()
      {:error, :no_stream, _} = TestConn.execute(Helpers.read_events(stream))
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # write two events after subscription
      events = [%Event.PersonCreated{name: "1"}, %Event.PersonCreated{name: "2"}]
      {:ok, _} = TestConn.execute(Helpers.write_events(stream, events))

      # assert rest events have arrived
      assert_receive {:on_event, _event}
      assert_receive {:on_event, _event}

      # check if only new events came in correct order.
      assert Subscriber.received_events(subscriber) == events

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "subscription to soft deleted stream is success" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # soft delete stream
      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(stream))

      # subscribe to stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # write two more events after subscription
      events2 = [%Event.PersonCreated{name: "4"}, %Event.PersonCreated{name: "5"}]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert rest events have arrived
      assert_receive {:on_event, _event}
      assert_receive {:on_event, _event}

      # check if only new events came in correct order.
      assert Subscriber.received_events(subscriber) == events2

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "soft deleting stream while subscription exists doesn't affect subscription" do
      stream = Helpers.random_stream_name()

      # subscribe to stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # write two events after subscription
      events2 = [%Event.PersonCreated{name: "1"}, %Event.PersonCreated{name: "2"}]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert events have arrived
      assert_receive {:on_event, _event}
      assert_receive {:on_event, _event}

      # soft delete stream
      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream))

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2
      # subscription is alive
      assert Process.alive?(subscription)
      assert Process.alive?(subscriber)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "hard deleting stream will close its subscription" do
      stream = Helpers.random_stream_name()

      # subscribe to stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # write two events after subscription
      events2 = [%Event.PersonCreated{name: "1"}, %Event.PersonCreated{name: "2"}]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert events have arrived
      assert_receive {:on_event, _event}
      assert_receive {:on_event, _event}

      # hard delete stream
      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))

      assert {:error, :stream_deleted, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream))

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2
      # ensure information of deleted stream is received
      assert_receive {:extreme, :stream_hard_deleted}
      # subscription is dead, but subscriber may survive
      assert Process.alive?(subscriber)
      :timer.sleep(10)
      refute Process.alive?(subscription)

      Helpers.assert_no_leaks(TestConn)
    end

    test "events are not pushed after unsubscribe" do
      stream = Helpers.random_stream_name()

      # subscribe to stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber)

      # push events
      events1 =
        1..3
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # ensure events are received
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # unsubscribe from stream
      Helpers.unsubscribe(TestConn, subscription)
      assert_receive {:extreme, :unsubscribed}

      # write more events after unsubscribe
      events2 =
        4..8
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are not received
      for _ <- 1..5, do: refute_receive({:on_event, _event})

      Helpers.assert_no_leaks(TestConn)
    end

    test "timeout for event processing can be adjusted" do
      sleep = 5_001
      # subscribe to stream
      stream = Helpers.random_stream_name()
      {:error, :no_stream, _} = TestConn.execute(Helpers.read_events(stream))
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.subscribe_to(stream, subscriber, true, sleep + 1_000)

      # write two events after subscription
      events = [%Event.SlowProcessingEventHappened{sleep: sleep}, %Event.PersonCreated{name: "2"}]
      {:ok, _} = TestConn.execute(Helpers.write_events(stream, events))

      # assert rest events have arrived
      assert_receive {:on_event, _event}, sleep + 1_000
      assert_receive {:on_event, _event}

      # check if only new events came in correct order.
      assert Subscriber.received_events(subscriber) == events

      Helpers.unsubscribe(TestConn, subscription)
    end
  end

  describe "event_producer" do
    test "for existing stream" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # assert first events are received
      for _ <- 1..3, do: assert_receive({:on_event, _event})
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "for non existing stream is ok" do
      stream = Helpers.random_stream_name()

      {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(stream))

      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # write more events after subscription
      num_additional_events = 100

      events =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "for soft deleted stream is ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # assert first events are receiveD
      for _ <- 1..3, do: refute_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive {:extreme, :warn, :stream_soft_deleted, ^stream}
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "read events and stay subscribed for recreated stream is ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      events2 = [
        %Event.PersonCreated{name: "4"},
        %Event.PersonCreated{name: "5"},
        %Event.PersonCreated{name: "6"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # assert first events are receiveD
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      refute_receive {:extreme, :warn, :stream_soft_deleted, ^stream}
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events3 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + 6}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events3))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2 ++ events3

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events2 ++ events3 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "read events and stay subscribed for hard deleted stream is not ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # assert :caught_up is received when existing events are read
      assert_receive {:extreme, :error, :stream_deleted, ^stream}

      # wait a bit but producer should not die
      :timer.sleep(10)
      assert Process.alive?(producer)
      Helpers.assert_no_leaks(TestConn)
    end

    test "events written while subscribing are also pushed to client in correct order" do
      stream = Helpers.random_stream_name()
      num_events = 200
      # prepopulate stream
      events1 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      events2 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + num_events}"} end)

      Enum.each(events1, fn e ->
        {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream, [e]))
      end)

      # bombard the stream with individual event writes in the background
      spawn(fn ->
        Enum.each(events2, fn e ->
          {:ok, %ExMsg.WriteEventsCompleted{}} =
            TestConn.execute(Helpers.write_events(stream, [e]))
        end)

        Logger.debug("Second pack of events written")
      end)

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      Logger.debug("Second pack of events written")

      # assert first events are received
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      Logger.debug("First pack of events received")

      # assert second pack of events is received as well
      for _ <- 1..num_events, do: assert_receive({:on_event, _event}, 1_000)

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 2_000))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "events written just after subscription starts are also pushed to client in correct order" do
      stream = Helpers.random_stream_name()
      num_events = 200
      # prepopulate stream
      events1 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      events2 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + num_events}"} end)

      Enum.each(events1, fn e ->
        {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream, [e]))
      end)

      spawn(fn ->
        Enum.each(events2, fn e ->
          {:ok, %ExMsg.WriteEventsCompleted{}} =
            TestConn.execute(Helpers.write_events(stream, [e]))
        end)

        Logger.debug("Second pack of events written")
      end)

      Process.sleep(100)

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      # TODO make it more likely or guaranteed that the race would fail

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: 5_000,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      Logger.debug("Second pack of events written")

      # assert first events are received
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      Logger.debug("First pack of events received")

      # assert second pack of events is received as well
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 2_000))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end

    test "ack timeout can be adjusted" do
      sleep = 5_001
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.SlowProcessingEventHappened{sleep: sleep},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      opts = [
        from_event_number: -1,
        per_page: 10,
        resolve_link_tos: true,
        require_master: false,
        ack_timeout: sleep + 10,
        max_buffered: 10,
        auto_subscribe: true
      ]

      {:ok, producer} = TestConn.start_event_producer(stream, subscriber, opts)

      # assert first events are received
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, producer)
    end
  end

  describe "read_and_stay_subscribed/6" do
    test "read events and stay subscribed for existing stream is ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2)

      # assert first events are received
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "read events and stay subscribed for non existing stream is ok" do
      stream = Helpers.random_stream_name()

      {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(stream))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 20)

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "read events and stay subscribed for soft deleted stream is ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2)

      # assert first events are receiveD
      for _ <- 1..3, do: refute_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive {:extreme, :warn, :stream_soft_deleted, ^stream}
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "read events and stay subscribed for recreated stream is ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      events2 = [
        %Event.PersonCreated{name: "4"},
        %Event.PersonCreated{name: "5"},
        %Event.PersonCreated{name: "6"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 3)

      # assert first events are receiveD
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      refute_receive {:extreme, :warn, :stream_soft_deleted, ^stream}
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events3 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + 6}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events3))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events2 ++ events3

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events2 ++ events3 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "read events and stay subscribed for hard deleted stream is not ok" do
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.PersonCreated{name: "1"},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2)

      # assert :caught_up is received when existing events are read
      assert_receive {:extreme, :error, :stream_deleted, ^stream}

      # wait a bit for process to die
      :timer.sleep(10)
      refute Process.alive?(subscription)
      Helpers.assert_no_leaks(TestConn)
    end

    test "events written while subscribing are also pushed to client in correct order" do
      stream = Helpers.random_stream_name()
      num_events = 200
      # prepopulate stream
      events1 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      events2 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + num_events}"} end)

      Enum.each(events1, fn e ->
        {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream, [e]))
      end)

      # bombard the stream with individual event writes in the background
      spawn(fn ->
        Enum.each(events2, fn e ->
          {:ok, %ExMsg.WriteEventsCompleted{}} =
            TestConn.execute(Helpers.write_events(stream, [e]))
        end)

        Logger.debug("Second pack of events written")
      end)

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()
      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2)

      Logger.debug("Second pack of events written")

      # assert first events are received
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      Logger.debug("First pack of events received")

      # assert second pack of events is received as well
      for _ <- 1..num_events, do: assert_receive({:on_event, _event}, 1_000)

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 2_000))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "events written just after subscription starts are also pushed to client in correct order" do
      stream = Helpers.random_stream_name()
      num_events = 200
      # prepopulate stream
      events1 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      events2 =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x + num_events}"} end)

      Enum.each(events1, fn e ->
        {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream, [e]))
      end)

      spawn(fn ->
        Enum.each(events2, fn e ->
          {:ok, %ExMsg.WriteEventsCompleted{}} =
            TestConn.execute(Helpers.write_events(stream, [e]))
        end)

        Logger.debug("Second pack of events written")
      end)

      Process.sleep(100)

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      # TODO make it more likely or guaranteed that the race would fail

      {:ok, subscription} = TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2)

      Logger.debug("Second pack of events written")

      # assert first events are received
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      Logger.debug("First pack of events received")

      # assert second pack of events is received as well
      for _ <- 1..num_events, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 2_000))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "ack timeout can be adjusted" do
      sleep = 5_001
      stream = Helpers.random_stream_name()
      # prepopulate stream
      events1 = [
        %Event.SlowProcessingEventHappened{sleep: sleep},
        %Event.PersonCreated{name: "2"},
        %Event.PersonCreated{name: "3"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events1))

      # subscribe to existing stream
      {:ok, subscriber} = Subscriber.start_link()

      {:ok, subscription} =
        TestConn.read_and_stay_subscribed(stream, subscriber, 0, 2, true, false, sleep + 10)

      # assert first events are received
      for _ <- 1..3, do: assert_receive({:on_event, _event})

      # assert :caught_up is received when existing events are read
      assert_receive :caught_up

      # write more events after subscription
      num_additional_events = 100

      events2 =
        1..num_additional_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events2))

      # assert new events are received as well
      for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

      # check if events came in correct order.
      assert Subscriber.received_events(subscriber) == events1 ++ events2

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events(stream, 0, 200))

      assert events1 ++ events2 ==
               Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

      Helpers.unsubscribe(TestConn, subscription)
    end

    test "backpressure" do
      stream = Helpers.random_stream_name()
      num_events = 1_000
      # prepopulate stream
      events =
        1..num_events
        |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      # subscribe to existing stream
      read_per_batch = 100
      {:ok, subscriber} = Subscriber.start_link()

      {:ok, subscription} =
        TestConn.read_and_stay_subscribed(stream, subscriber, 0, read_per_batch)

      connection =
        Extreme.Connection._name(TestConn)
        |> Process.whereis()

      request_manager =
        Extreme.RequestManager._name(TestConn)
        |> Process.whereis()

      for _ <- 1..num_events do
        {:message_queue_len, len} = Process.info(subscriber, :message_queue_len)
        assert len < 2
        {:message_queue_len, len} = Process.info(subscription, :message_queue_len)
        assert len < 2
        {:message_queue_len, len} = Process.info(connection, :message_queue_len)
        assert len < 2
        {:message_queue_len, len} = Process.info(request_manager, :message_queue_len)
        assert len < 2

        assert_receive({:on_event, _event})
        Process.sleep(10)
      end

      # assert :caught_up is received when all events are read
      assert_receive :caught_up

      Helpers.unsubscribe(TestConn, subscription)
    end
  end
end
