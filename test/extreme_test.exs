defmodule ExtremeTest do
  use ExUnit.Case, async: true
  use ExVCR.Mock, adapter: ExVCR.Adapter.Httpc

  alias ExtremeTest.Helpers
  alias ExtremeTest.Events, as: Event
  alias Extreme.Messages, as: ExMsg

  describe "start_link/2" do
    test "accepts configuration and makes connection" do
      assert TestConn
             |> Extreme.RequestManager._name()
             |> Process.whereis()
             |> Process.alive?()

      assert :pong == TestConn.ping()
    end

    defmodule(ClusterConn, do: use(Extreme))

    test "Connects on EventStore cluster with a list of nodes" do
      use_cassette "gossip_with_clusters_existing_node" do
        nodes = [
          %{host: "0.0.0.0", port: 2113}
        ]

        {:ok, _} =
          :extreme
          |> Application.get_env(TestConn)
          |> Keyword.delete(:host)
          |> Keyword.put(:db_type, "cluster")
          |> Keyword.put(:gossip_timeout, 20_000)
          |> Keyword.put(:nodes, nodes)
          |> ClusterConn.start_link()

        assert :pong == ClusterConn.ping()
      end
    end
  end

  describe "Authentication" do
    defmodule(ForbiddenConn, do: use(Extreme))

    @tag :authentication
    test ".execute/1 is not authenticated for wrong credentials" do
      {:ok, _} =
        :extreme
        |> Application.get_env(TestConn)
        |> Keyword.put(:password, "wrong")
        |> Keyword.put(:port, 1113)
        |> ForbiddenConn.start_link()

      assert {:error, :not_authenticated} = ForbiddenConn.execute(Helpers.write_events())
    end
  end

  describe "Heartbeat" do
    defmodule(SecondConn, do: use(Extreme))

    test "works when connection is idle" do
      {:ok, _} =
        :extreme
        |> Application.get_env(TestConn)
        |> SecondConn.start_link()

      :timer.sleep(5_000)

      assert :pong == SecondConn.ping()
    end
  end

  describe "Writing events" do
    test "for non existing stream is success" do
      assert {:ok,
              %ExMsg.WriteEventsCompleted{
                current_version: 0,
                first_event_number: 0,
                last_event_number: 1
              }} = TestConn.execute(Helpers.write_events())
    end

    test "for existing stream is success" do
      stream = Helpers.random_stream_name()

      assert {:ok,
              %ExMsg.WriteEventsCompleted{
                current_version: 0,
                first_event_number: 0,
                last_event_number: 1
              }} = TestConn.execute(Helpers.write_events(stream))

      assert {:ok,
              %ExMsg.WriteEventsCompleted{
                current_version: 0,
                first_event_number: 2,
                last_event_number: 3
              }} = TestConn.execute(Helpers.write_events(stream))
    end

    test "for soft deleted stream is success" do
      stream = Helpers.random_stream_name()

      assert {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream))

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:ok,
              %ExMsg.WriteEventsCompleted{
                current_version: 0,
                first_event_number: 2,
                last_event_number: 3
              }} = TestConn.execute(Helpers.write_events(stream))
    end

    test "for hard deleted stream is rejected" do
      stream = Helpers.random_stream_name()

      assert {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream))

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, true))

      assert {:error, :stream_deleted, %ExMsg.WriteEventsCompleted{}} =
               TestConn.execute(Helpers.write_events(stream))
    end
  end

  describe "Reading events" do
    test "is success when response data is received in more tcp packages" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Reading"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"},
        %Event.PersonChangedName{name: "Reading Test"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      {:ok, %ExMsg.ReadStreamEventsCompleted{events: read_events, is_end_of_stream: true}} =
        TestConn.execute(Helpers.read_events(stream, 0, 20))

      assert events ==
               Enum.map(read_events, fn event -> :erlang.binary_to_term(event.event.data) end)
    end

    test "reads correct big integer when written as term" do
      stream = Helpers.random_stream_name()
      number_1 = 6_553_255_926_290_448_384
      number_2 = 25_000_000_000_000_000_000

      [event_1, event_2] =
        events = [
          %Event.BigNumberAdded{number: number_1},
          %Event.BigNumberAdded{number: number_2}
        ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      {:ok, %ExMsg.ReadStreamEventsCompleted{events: read_events, is_end_of_stream: true}} =
        TestConn.execute(Helpers.read_events(stream, 0, 2))

      assert [ev1, ev2] = read_events

      assert event_1 == :erlang.binary_to_term(ev1.event.data)
      assert event_2 == :erlang.binary_to_term(ev2.event.data)
    end

    test "reads correct big integer when written as json" do
      stream = Helpers.random_stream_name()
      number_1 = 6_553_255_926_290_448_384
      number_2 = 25_000_000_000_000_000_000

      [event_1, event_2] =
        events = [
          %Event.BigNumberMapAdded{number_map: %{number: number_1}},
          %Event.BigNumberMapAdded{number_map: %{number: number_2}}
        ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_json_events(stream, events))

      {:ok, %ExMsg.ReadStreamEventsCompleted{events: read_events, is_end_of_stream: true}} =
        TestConn.execute(Helpers.read_events(stream, 0, 2))

      assert [^event_1, ^event_2] =
               read_events
               |> Enum.map(fn ev ->
                 event_type = ev.event.event_type |> String.to_existing_atom()
                 event = Jason.decode!(ev.event.data, keys: :atoms)
                 struct!(event_type, event)
               end)
    end

    test "from non existing stream returns {:error, :no_stream, %ReadStreamEventsCompleted{}}" do
      {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(Helpers.random_stream_name()))
    end

    test "from soft deleted stream returns {:error, :no_stream, %ReadStreamEventsCompleted{}}" do
      stream = Helpers.random_stream_name()
      {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(stream))
    end

    test "from hard deleted stream returns {:error, :stream_deleted, %ReadStreamEventsCompleted{}}" do
      stream = Helpers.random_stream_name()
      {:ok, %ExMsg.WriteEventsCompleted{}} = TestConn.execute(Helpers.write_events(stream))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))

      {:error, :stream_deleted, %ExMsg.ReadStreamEventsCompleted{}} =
        TestConn.execute(Helpers.read_events(stream))
    end

    test "backward is success" do
      stream = Helpers.random_stream_name()

      events =
        [event1, event2] = [
          %Event.PersonCreated{name: "Reading"},
          %Event.PersonChangedName{name: "Reading Test"}
        ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
        TestConn.execute(Helpers.read_events_backward(stream, -1, 100))

      assert %{is_end_of_stream: true, last_event_number: 1, next_event_number: -1} = response
      assert [ev2, ev1] = response.events
      assert event2 == :erlang.binary_to_term(ev2.event.data)
      assert event1 == :erlang.binary_to_term(ev1.event.data)
      assert ev2.event.event_number == 1
      assert ev1.event.event_number == 0
    end

    test "backwards can give last event" do
      stream = Helpers.random_stream_name()

      events =
        [_, event2] = [
          %Event.PersonCreated{name: "Reading"},
          %Event.PersonChangedName{name: "Reading Test"}
        ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{} = response} =
               TestConn.execute(Helpers.read_events_backward(stream, -1, 1))

      assert %{is_end_of_stream: false, last_event_number: 1, next_event_number: 0} = response
      assert [ev2] = response.events
      assert event2 == :erlang.binary_to_term(ev2.event.data)
      assert ev2.event.event_number == 1
    end
  end

  describe "Reading single event" do
    test "is success if event exists" do
      stream = Helpers.random_stream_name()

      events = [
        expected_event = %Event.PersonCreated{name: "Reading"},
        %Event.PersonChangedName{name: "Reading Test"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadEventCompleted{} = response} =
               TestConn.execute(Helpers.read_event(stream, 0))

      assert expected_event == :erlang.binary_to_term(response.event.event.data)
    end

    test "is success for last event (position: -1)" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Reading"},
        %Event.PersonChangedName{name: "Reading Test"},
        expected_event = %Event.PersonChangedName{name: "Reading Test 2"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadEventCompleted{} = response} =
               TestConn.execute(Helpers.read_event(stream, -1))

      assert expected_event == :erlang.binary_to_term(response.event.event.data)
    end

    test "returns {:error, :not_found, %ReadEventCompleted{}} for non existing event" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Reading"},
        %Event.PersonChangedName{name: "Reading Test"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:error, :not_found, %ExMsg.ReadEventCompleted{}} =
               TestConn.execute(Helpers.read_event(stream, 2))
    end

    test "returns {:error, :bad_request} for position < -1" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Reading"},
        %Event.PersonChangedName{name: "Reading Test"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:error, :bad_request} = TestConn.execute(Helpers.read_event(stream, -2))
    end

    test "returns {:error, :no_stream, %ReadEventCompleted{}} for non existing stream" do
      stream = Helpers.random_stream_name()

      assert {:error, :no_stream, %ExMsg.ReadEventCompleted{}} =
               TestConn.execute(Helpers.read_event(stream, 0))
    end

    test "returns {:error, :no_stream, %ExMsg.ReadEventCompleted} for soft deleted event" do
      stream = Helpers.random_stream_name()

      events = [
        expected_event = %Event.PersonCreated{name: "Reading 1"},
        %Event.PersonChangedName{name: "Reading Test 2"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, response} = TestConn.execute(Helpers.read_event(stream, 0))
      assert expected_event == :erlang.binary_to_term(response.event.event.data)

      # soft delete stream

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadEventCompleted{}} =
               TestConn.execute(Helpers.read_event(stream, 0))
    end

    test "returns {:error, :stream_deleted, %ExMsg.ReadEventCompleted} for hard deleted event" do
      stream = Helpers.random_stream_name()

      events = [
        expected_event = %Event.PersonCreated{name: "Reading 1"},
        %Event.PersonChangedName{name: "Reading Test 2"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadEventCompleted{} = response} =
               TestConn.execute(Helpers.read_event(stream, 0))

      assert expected_event == :erlang.binary_to_term(response.event.event.data)

      # hard delete stream

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))

      assert {:error, :stream_deleted, %ExMsg.ReadEventCompleted{}} =
               TestConn.execute(Helpers.read_event(stream, 0))
    end
  end

  describe "Soft deleting stream" do
    test "multiple times in a row is ok" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Name 1"},
        %Event.PersonChangedName{name: "Name Changed 1"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # soft delete stream

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))
    end

    test "can be done after writing to soft deleted stream" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Name 1"},
        %Event.PersonChangedName{name: "Name Changed 1"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # soft delete stream

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # write again events
      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # soft delete stream again

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))
    end

    test "that doesn't exist is ok" do
      stream = Helpers.random_stream_name()

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, false))
    end

    test "can't be done after stream is hard deleted" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Name 1"},
        %Event.PersonChangedName{name: "Name Changed 1"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # hard delete stream

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, true))

      assert {:error, :stream_deleted, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # soft delete stream

      assert {:error, :stream_deleted, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, false))
    end
  end

  describe "Hard deleting stream" do
    test "multiple times in a row is not ok" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Name 1"},
        %Event.PersonChangedName{name: "Name Changed 1"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # hard delete stream

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, true))

      assert {:error, :stream_deleted, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      assert {:error, :stream_deleted, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, true))
    end

    test "can be done after stream is soft deleted" do
      stream = Helpers.random_stream_name()

      events = [
        %Event.PersonCreated{name: "Name 1"},
        %Event.PersonChangedName{name: "Name Changed 1"}
      ]

      {:ok, %ExMsg.WriteEventsCompleted{}} =
        TestConn.execute(Helpers.write_events(stream, events))

      assert {:ok, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # soft delete stream

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, false))

      assert {:error, :no_stream, %ExMsg.ReadStreamEventsCompleted{}} =
               TestConn.execute(Helpers.read_events(stream, 0, 2))

      # hard delete stream

      assert {:ok, %ExMsg.DeleteStreamCompleted{}} =
               TestConn.execute(Helpers.delete_stream(stream, true))
    end

    test "that doesn't exist is ok" do
      stream = Helpers.random_stream_name()

      {:ok, %ExMsg.DeleteStreamCompleted{}} =
        TestConn.execute(Helpers.delete_stream(stream, true))
    end
  end
end
