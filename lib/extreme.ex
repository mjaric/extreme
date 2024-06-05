defmodule Extreme do
  @moduledoc """
  TODO
  """

  @type t :: module

  @doc false
  defmacro __using__(opts \\ []) do
    quote do
      @otp_app Keyword.get(unquote(opts), :otp_app, :extreme)

      defp _default_config,
        do: Application.get_env(@otp_app, __MODULE__)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(config \\ [])
      def start_link([]), do: Extreme.Supervisor.start_link(__MODULE__, _default_config())
      def start_link(config), do: Extreme.Supervisor.start_link(__MODULE__, config)

      def ping,
        do: Extreme.RequestManager.ping(__MODULE__, Extreme.Tools.generate_uuid())

      def execute(message, correlation_id \\ nil, timeout \\ 5_000) do
        Extreme.RequestManager.execute(
          __MODULE__,
          message,
          correlation_id || Extreme.Tools.generate_uuid(),
          timeout
        )
      end

      def subscribe_to(stream, subscriber, resolve_link_tos \\ true, ack_timeout \\ 5_000)
          when is_binary(stream) and is_pid(subscriber) and is_boolean(resolve_link_tos) do
        Extreme.RequestManager.subscribe_to(
          __MODULE__,
          stream,
          subscriber,
          resolve_link_tos,
          ack_timeout
        )
      end

      def read_and_stay_subscribed(
            stream,
            subscriber,
            from_event_number \\ 0,
            per_page \\ 1_000,
            resolve_link_tos \\ true,
            require_master \\ false,
            ack_timeout \\ 5_000
          )
          when is_binary(stream) and is_pid(subscriber) and is_boolean(resolve_link_tos) and
                 is_boolean(require_master) and from_event_number > -2 and per_page >= 0 and
                 per_page <= 4096 do
        Extreme.RequestManager.read_and_stay_subscribed(
          __MODULE__,
          subscriber,
          {stream, from_event_number, per_page, resolve_link_tos, require_master, ack_timeout}
        )
      end

      def start_event_producer(stream, subscriber, opts \\ []) do
        Extreme.SubscriptionsSupervisor.start_event_producer(
          __MODULE__,
          [{:stream, stream}, {:subscriber, subscriber} | opts]
        )
      end

      def unsubscribe(subscription) when is_pid(subscription),
        do: Extreme.Subscription.unsubscribe(subscription)

      def connect_to_persistent_subscription(
            subscriber,
            stream,
            group,
            allowed_in_flight_messages
          ) do
        Extreme.RequestManager.connect_to_persistent_subscription(
          __MODULE__,
          subscriber,
          stream,
          group,
          allowed_in_flight_messages
        )
      end
    end
  end

  @doc """
  TODO
  """
  @callback start_link(config :: Keyword.t(), opts :: Keyword.t()) ::
              {:ok, pid}
              | {:error, {:already_started, pid}}
              | {:error, term}

  @doc """
  TODO
  """
  @callback execute(message :: term(), correlation_id :: binary(), timeout :: integer()) :: term()

  @doc """
  TODO
  """
  @callback subscribe_to(stream :: String.t(), subscriber :: pid(), opts :: Keyword.t()) ::
              {:ok, pid}

  @doc """
  TODO
  """
  @callback unsubscribe(subscription :: pid()) :: :unsubscribed

  @doc """
  TODO
  """
  @callback read_and_stay_subscribed(
              stream :: String.t(),
              subscriber :: pid(),
              from_event_number :: integer(),
              per_page :: integer(),
              resolve_link_tos :: boolean(),
              require_master :: boolean()
            ) :: {:ok, pid()}

  @doc """
  Pings connected EventStore and should return `:pong` back.
  """
  @callback ping() :: :pong

  @doc """
  Spawns a persistent subscription.

  The persistent subscription will send events to the `subscriber` process in
  the form of `GenServer.cast/2`s in the shape of `{:on_event, event,
  correlation_id}`.

  See `Extreme.PersistentSubscription` for full details.
  """
  @callback connect_to_persistent_subscription(
              subscriber :: pid(),
              stream :: String.t(),
              group :: String.t(),
              allowed_in_flight_messages :: integer()
            ) :: {:ok, pid()}
end
