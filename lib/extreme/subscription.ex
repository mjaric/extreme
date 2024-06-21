defmodule Extreme.Subscription do
  use GenServer
  require Logger
  alias Extreme.SharedSubscription, as: Shared

  defmodule State do
    defstruct ~w(base_name correlation_id subscriber stream read_params status)a
  end

  def start_link(
        base_name,
        correlation_id,
        subscriber,
        stream,
        resolve_link_tos,
        ack_timeout \\ 5_000
      ) do
    GenServer.start_link(
      __MODULE__,
      {base_name, correlation_id, subscriber, stream, resolve_link_tos, ack_timeout}
    )
  end

  @doc """
  Calls `server` with :unsubscribe message. `server` can be either `Subscription` or `ReadingSubscription`.
  """
  def unsubscribe(server),
    do: GenServer.cast(server, :unsubscribe)

  @impl GenServer
  def init({base_name, correlation_id, subscriber, stream, resolve_link_tos, ack_timeout}) do
    read_params = %{stream: stream, resolve_link_tos: resolve_link_tos, ack_timeout: ack_timeout}

    state = %State{
      base_name: base_name,
      correlation_id: correlation_id,
      subscriber: subscriber,
      read_params: read_params,
      status: :initialized
    }

    {:ok, _} = Shared.subscribe(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(:unsubscribe, state) do
    :ok = Shared.unsubscribe(state)
    {:noreply, state}
  end

  def handle_cast({:process_push, fun}, state),
    do: Shared.process_push(fun, state)
end
