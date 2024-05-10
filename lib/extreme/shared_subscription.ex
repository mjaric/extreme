defmodule Extreme.SharedSubscription do
  @moduledoc """
  This module contains functions shared between `Extreme.Subscription` and `Extreme.ReadingSubscription`.
  """

  alias Extreme.RequestManager
  alias Extreme.Messages, as: Msg
  require Logger

  @doc """
  Sends subscription request and waits for positive response. Returns `{:ok, subscription_confirmation}`.
  """
  def subscribe(state) do
    message =
      Msg.SubscribeToStream.new(
        event_stream_id: state.read_params.stream,
        resolve_link_tos: state.read_params.resolve_link_tos
      )

    {:ok, subscription_confirmation} =
      state.base_name
      |> RequestManager.execute(message, state.correlation_id)

    Logger.debug(fn ->
      "Successfully subscribed to stream #{inspect(subscription_confirmation)}"
    end)

    {:ok, subscription_confirmation}
  end

  @doc """
  Sends unsubscribe request and remembers who it should respond to when response is received.
  Response will arrive to subscription as push message.
  """
  def unsubscribe(from, state) do
    message = Msg.UnsubscribeFromStream.new()

    spawn_link(fn ->
      state.base_name
      |> RequestManager.execute(message, state.correlation_id)
    end)

    Process.put(:reply_to, from)

    :ok
  end

  @doc """
  Executes `fun` function for decoding response and responds on that message.
  """
  def process_push(fun, state), do: fun.() |> _process_push(state)

  @doc """
  Calls subscriber with {:on_event, event}, expecting :ok as result
  in order to apply backpressure.
  """
  def on_event(subscriber, event, ack_timeout),
    do: GenServer.call(subscriber, {:on_event, event}, ack_timeout)

  defp _process_push(
         {_auth, _correlation_id,
          %Msg.StreamEventAppeared{
            event: %Msg.ResolvedEvent{event: %Msg.EventRecord{event_type: "$streamDeleted"}}
          }},
         state
       ) do
    send(state.subscriber, {:extreme, :stream_hard_deleted})
    RequestManager.unregister_subscription(state.base_name, state.correlation_id)
    {:stop, {:shutdown, :stream_hard_deleted}, state}
  end

  defp _process_push(
         {_auth, _correlation_id, %Msg.StreamEventAppeared{} = e},
         state
       ) do
    state.subscriber
    |> on_event(e.event, state.read_params.ack_timeout)
    |> case do
      :ok ->
        {:noreply, state}

      :stop ->
        Logger.warning("Processing of event requested stopping subscription")
        RequestManager.unregister_subscription(state.base_name, state.correlation_id)
        {:stop, {:shutdown, :processing_of_event_requested_stopping_subscription}, state}
    end
  end

  defp _process_push(
         {_auth, _correlation_id, %Msg.SubscriptionDropped{reason: reason}},
         state
       ) do
    send(state.subscriber, {:extreme, reason})
    RequestManager.unregister_subscription(state.base_name, state.correlation_id)

    case Process.get(:reply_to) do
      nil -> :ok
      from -> GenServer.reply(from, reason)
    end

    {:stop, {:shutdown, reason}, state}
  end

  defp _process_push(
         {_auth, _correlation_id,
          %Msg.PersistentSubscriptionConfirmation{subscription_id: subscription_id} = confirmation},
         state
       ) do
    Logger.debug(fn -> "Successfully subscribed #{inspect(confirmation)}" end)

    {:noreply, %{state | status: :subscribed, subscription_id: subscription_id}}
  end

  defp _process_push(
         {_auth, correlation_id, %Msg.PersistentSubscriptionStreamEventAppeared{} = e},
         state
       ) do
    :ok = GenServer.cast(state.subscriber, {:on_event, e.event, correlation_id})

    {:noreply, state}
  end
end
