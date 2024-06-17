defmodule Extreme.ListenerWithBackPressure do
  @moduledoc ~S"""
  The same as `Extreme.Listener` but uses event_producer functionality which applies backpressure
  on live events as well.

  The way it works is that there's intermediate process which turns off subscription when `max_buffer` is reached
  and creates new subscription when all buffered events are processed.
  """
  defmacro __using__(_) do
    quote location: :keep do
      use GenServer
      require Logger

      def child_spec([extreme, stream_name | opts]) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [extreme, stream_name, opts]}
        }
      end

      @doc """
      Starts Listener GenServer with `extreme` connection, for particular `stream_name`
      and options:

      * `:name` of listener process. Defaults to module name.
      * `:read_per_page` - number of events read in batches until all existing evets are processed. Defaults to 100
      * `:resolve_link_tos` - weather to resolve event links. Defaults to `true`.
      * `:require_master` - check if events are expected from master ES node. Defaults to `false`.
      * `:ack_timeout` - Wait time for ack message. Defaults to 5_000 ms.
      * `:auto_subscribe` - indicates if subscription should be started as soon as process starts. Defaults to `true`
      * `:max_buffered` - Number of unprocessed but received events when backpressure should be applied.
         Defaults to `read_per_page * 2`
      """
      def start_link(extreme, stream_name, opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        opts = Keyword.put(opts, :stream, stream_name)

        GenServer.start_link(__MODULE__, {extreme, opts}, name: name)
      end

      def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)
      def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)
      def subscribed?(server \\ __MODULE__), do: GenServer.call(server, :subscribed?)
      def producer_status(server \\ __MODULE__), do: GenServer.call(server, :producer_status)

      @impl GenServer
      def init({extreme, opts}) do
        :ok = on_init(opts)
        stream_name = Keyword.fetch!(opts, :stream)
        last_event = get_last_event(stream_name)

        {:ok, producer} = extreme.start_event_producer(stream_name, self(), opts)
        _ref = Process.monitor(producer)

        Logger.info(
          "#{__MODULE__} started event producer for stream #{stream_name} with event no: #{last_event + 1}"
        )

        {:ok,
         %{
           stream_name: stream_name,
           extreme: extreme,
           producer: producer
         }}
      end

      @impl GenServer
      def handle_call({:on_event, push}, _from, %{} = state) do
        response = process_push(push, state.stream_name)

        {:reply, response, state}
      end

      def handle_call(:subscribe, _from, state) do
        response = state.extreme.subscribe_producer(state.producer)
        {:reply, response, state}
      end

      def handle_call(:unsubscribe, _from, state) do
        :unsubscribed = state.extreme.unsubscribe_producer(state.producer)
        {:reply, :ok, state}
      end

      def handle_call(:subscribed?, _from, state) do
        response = state.extreme.producer_subscription_status(state.producer) != :disconnected
        {:reply, response, state}
      end

      def handle_call(:producer_status, _from, state) do
        response = state.extreme.producer_subscription_status(state.producer)
        {:reply, response, state}
      end

      @impl GenServer
      def handle_info(_, %{} = state),
        do: {:noreply, state}

      def on_init(_), do: :ok

      defoverridable on_init: 1
    end
  end
end
