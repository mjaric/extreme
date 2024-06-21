defmodule Extreme.ListenerTest do
  use ExUnit.Case, async: false
  alias ExtremeTest.{Helpers, DB}
  alias ExtremeTest.Events, as: Event
  alias Extreme.Messages, as: ExMsg
  require Logger

  defmodule MyListener do
    use Extreme.Listener
    alias ExtremeTest.DB

    defp get_last_event(stream_name),
      do: DB.get_last_event(MyListener, stream_name)

    defp process_push(push, stream_name) do
      event_number = push.event.event_number

      # for indexed stream we need to follow link event_number:
      # event_number = push.link.event_number

      sleep =
        push.event.data
        |> :erlang.binary_to_term()
        |> case do
          %ExtremeTest.Events.SlowProcessingEventHappened{sleep: sleep} -> sleep
          _ -> 1
        end

      DB.in_transaction(fn ->
        :timer.sleep(sleep)
        send(:test, {:processing_push, push.event.event_type, push.event.data})
        :ok = DB.ack_event(MyListener, stream_name, event_number)
        Logger.debug(fn -> "Processed event ##{event_number}" end)
      end)

      {:ok, event_number}
    end

    # This override is optional
    def caught_up, do: Logger.debug("We are up to date. YEEEY!!!")
  end

  setup do
    Process.sleep(100)
    {:ok, _db} = DB.start_link()
    Process.register(self(), :test)
    :ok
  end

  test "Listener reads all events if never run before" do
    stream = Helpers.random_stream_name()
    event1 = %Event.PersonCreated{name: "Pera"}
    event2 = %Event.PersonChangedName{name: "Zika"}
    event3 = %Event.PersonChangedName{name: "Laza"}

    assert DB.get_last_event(MyListener, stream) == -1

    # write 2 events to stream
    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event1, event2]))

    # run listener and expect it to read them
    {:ok, listener} = MyListener.start_link(TestConn, stream, read_per_page: 2)
    assert MyListener.subscribed?(listener)

    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonCreated"
    assert event1 == :erlang.binary_to_term(event)
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event2 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 1

    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event3]))

    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event3 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 2

    :ok = MyListener.unsubscribe(listener)
    refute MyListener.subscribed?(listener)
    # unsubscribe is idempotent
    :ok = MyListener.unsubscribe(listener)
    Helpers.assert_no_leaks(TestConn)
  end

  test "ack timeout can be adjusted" do
    sleep = 5_001
    stream = Helpers.random_stream_name()
    event1 = %Event.SlowProcessingEventHappened{sleep: sleep}
    event2 = %Event.PersonChangedName{name: "Zika"}
    event3 = %Event.PersonChangedName{name: "Laza"}

    assert DB.get_last_event(MyListener, stream) == -1

    # write 2 events to stream
    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event1, event2]))

    # run listener and expect it to read them
    {:ok, listener} =
      MyListener.start_link(TestConn, stream, read_per_page: 2, ack_timeout: sleep + 1_000)

    assert_receive {:processing_push, event_type, event}, sleep + 1_000
    assert event_type == "Elixir.ExtremeTest.Events.SlowProcessingEventHappened"
    assert event1 == :erlang.binary_to_term(event)
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event2 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 1

    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event3]))

    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event3 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 2

    :ok = MyListener.unsubscribe(listener)
    Helpers.assert_no_leaks(TestConn)
  end

  test "subscribe/unsubscribe" do
    stream = Helpers.random_stream_name()
    event1 = %Event.PersonCreated{name: "Pera"}
    event2 = %Event.PersonChangedName{name: "Zika"}
    event3 = %Event.PersonChangedName{name: "Laza"}

    assert DB.get_last_event(MyListener, stream) == -1

    # write 2 events to stream
    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event1, event2]))

    # run listener and expect it to read them
    {:ok, _listener} = MyListener.start_link(TestConn, stream, read_per_page: 2)
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonCreated"
    assert event1 == :erlang.binary_to_term(event)
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event2 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 1

    # unsubscribe and write new event
    :ok = MyListener.unsubscribe()

    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event3]))

    # new event is not processed
    refute_receive {:processing_push, _event_type, _event}

    # when subscribed again, listener resumes where it stopped
    :ok = MyListener.subscribe()

    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event3 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 2

    refute_receive {:processing_push, _event_type, _event}

    :ok = MyListener.unsubscribe()
    Helpers.assert_no_leaks(TestConn)
  end

  test "auto_subscribe? can be turned off" do
    stream = Helpers.random_stream_name()
    event1 = %Event.PersonCreated{name: "Pera"}
    event2 = %Event.PersonChangedName{name: "Zika"}

    assert DB.get_last_event(MyListener, stream) == -1

    {:ok, %ExMsg.WriteEventsCompleted{}} =
      TestConn.execute(Helpers.write_events(stream, [event1, event2]))

    # run listener and expect they are not processed
    {:ok, _listener} =
      MyListener.start_link(TestConn, stream, read_per_page: 2, auto_subscribe?: false)

    refute_receive {:processing_push, _event_type, _event}, 1_000

    # turn on subscription and expect that events are processed
    :ok = MyListener.subscribe()
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonCreated"
    assert event1 == :erlang.binary_to_term(event)
    assert_receive {:processing_push, event_type, event}
    assert event_type == "Elixir.ExtremeTest.Events.PersonChangedName"
    assert event2 == :erlang.binary_to_term(event)
    assert DB.get_last_event(MyListener, stream) == 1

    :ok = MyListener.unsubscribe()
    Helpers.assert_no_leaks(TestConn)
  end
end
