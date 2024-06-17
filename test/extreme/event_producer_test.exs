defmodule Extreme.EventProducerTest do
  use ExUnit.Case, async: false
  alias ExtremeTest.Helpers
  alias ExtremeTest.Events, as: Event
  alias Extreme.Messages, as: ExMsg
  require Logger

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

    TestConn.Connection
    |> Process.whereis()
    |> send({:tcp_closed, 1113})

    # event_producer will try to resubscribe on crash after 1000ms
    # we are trying to catch both persisted and live events, hence sleep of 950
    Process.sleep(950)

    # write more events after subscription
    num_additional_events = 100

    events2 =
      1..num_additional_events
      |> Enum.map(fn x -> %Event.PersonCreated{name: "Name #{x}"} end)

    spawn(fn ->
      events2
      |> Enum.each(fn event ->
        {:ok, %ExMsg.WriteEventsCompleted{}} =
          TestConn.execute(Helpers.write_events(stream, [event]))
      end)
    end)

    # assert new events are received as well
    for _ <- 1..num_additional_events, do: assert_receive({:on_event, _event})

    # check if events came in correct order.
    assert Subscriber.received_events(subscriber) == events1 ++ events2

    {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
      TestConn.execute(Helpers.read_events(stream, 0, 200))

    assert events1 ++ events2 ==
             Enum.map(response.events, fn event -> :erlang.binary_to_term(event.event.data) end)

    assert Process.alive?(producer)

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

  test "for recreated stream is ok" do
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

  test "for hard deleted stream is not ok" do
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

  test "subscriber can stop delivering of new events in processing response" do
    stream = Helpers.random_stream_name()
    # prepopulate stream
    events1 = [
      %Event.PersonCreated{name: "1"},
      %Event.PersonCreated{name: "2"},
      # this will stop processing only first time
      %Event.StopOnThisOne{times: 1},
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
    assert :catching_up = TestConn.producer_subscription_status(producer)

    # assert first 3 events are received
    for _ <- 1..3, do: assert_receive({:on_event, _event})
    # forth one should not be delivered
    refute_receive({:on_event, _event})

    assert :disconnected = TestConn.producer_subscription_status(producer)
    :ok = TestConn.subscribe_producer(producer)
    # we should get previously stopped event and the one after that
    for _ <- 1..2, do: assert_receive({:on_event, _event})
    assert :catching_up = TestConn.producer_subscription_status(producer)

    Process.sleep(50)
    assert :live = TestConn.producer_subscription_status(producer)

    # check if events are processed in correct order.
    assert Subscriber.received_events(subscriber) == events1

    # We can manually stop subscription without killing subscriber or producer
    :unsubscribed = TestConn.unsubscribe_producer(producer)
    assert :disconnected = TestConn.producer_subscription_status(producer)

    # then new events are not delivered to subscriber
    events2 = [
      %Event.PersonCreated{name: "4"}
    ]

    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, events2))

    refute_receive({:on_event, _event})

    # and then when we resubscribe, we'll get pending event
    :ok = TestConn.subscribe_producer(producer)
    assert_receive({:on_event, _event})
    assert :catching_up = TestConn.producer_subscription_status(producer)

    Helpers.unsubscribe(TestConn, producer)
  end
end
