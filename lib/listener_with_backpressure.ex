defmodule Extreme.ListenerWithBackPressure do
  @moduledoc ~S"""
  The same as `Extreme.Listener` but uses event_producer functionality which applies backpressure
  on live events as well.

  The way it works is that there's intermediate process which turns off subscription when `max_buffer` is reached
  and creates new subscription when all buffered events are processed.
  """

  @callback on_init(opts_from_start_link :: Keyword.t()) :: :ok | {:ok, client_state :: any()}
  @callback get_last_event(stream_name :: String.t(), client_state :: any()) ::
              last_event :: integer()
  @callback process_push(
              push_from_es :: Extreme.Messages.ResolvedEvent.t(),
              stream_name :: String.t(),
              client_state :: any()
            ) ::
              {:ok, event_number :: non_neg_integer()}
              | :ok
              | :stop

  defmacro __using__(_) do
    quote location: :keep do
      use GenServer
      @behaviour Extreme.ListenerWithBackPressure
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
      def unsubscribe(server \\ __MODULE__), do: GenServer.cast(server, :unsubscribe)
      def subscribed?(server \\ __MODULE__), do: GenServer.call(server, :subscribed?)
      def producer_status(server \\ __MODULE__), do: GenServer.call(server, :producer_status)

      @impl GenServer
      def init({extreme, opts}) do
        client_state =
          opts
          |> on_init()
          |> case do
            :ok -> %{}
            {:ok, client_state} -> client_state
          end

        stream_name = Keyword.fetch!(opts, :stream)
        last_event = fn -> get_last_event(stream_name, client_state) end

        opts = [
          {:from_event_number, last_event},
          {:per_page, Keyword.get(opts, :read_per_page, 100)}
          | opts
        ]

        {:ok, producer} = extreme.start_event_producer(stream_name, self(), opts)
        _ref = Process.monitor(producer)

        Logger.info("#{__MODULE__} started event producer on stream #{stream_name}")

        {:ok,
         %{
           client_state: client_state,
           stream_name: stream_name,
           extreme: extreme,
           producer: producer
         }}
      end

      @impl GenServer
      def handle_call({:on_event, push}, _from, %{} = state) do
        response = process_push(push, state.stream_name, state.client_state)

        {:reply, response, state}
      end

      def handle_call(:subscribe, _from, state) do
        response = state.extreme.subscribe_producer(state.producer)
        {:reply, response, state}
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
      def handle_cast(:unsubscribe, state) do
        :ok = state.extreme.unsubscribe_producer(state.producer)
        {:noreply, state}
      end

      @impl GenServer
      def handle_info(_, %{} = state),
        do: {:noreply, state}

      @impl Extreme.ListenerWithBackPressure
      def on_init(_), do: :ok

      defoverridable on_init: 1
    end
  end
end
