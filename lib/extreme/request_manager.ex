defmodule Extreme.RequestManager do
  use GenServer
  alias Extreme.SubscriptionsSupervisor
  alias Extreme.{Tools, Configuration, Request, Response, Connection}
  require Logger

  @read_only_message_types [
    Extreme.Messages.ReadEvent,
    Extreme.Messages.ReadStreamEvents,
    Extreme.Messages.ReadStreamEventsBackward,
    Extreme.Messages.ReadAllEvents,
    Extreme.Messages.ConnectToPersistentSubscription,
    Extreme.Messages.SubscribeToStream,
    Extreme.Messages.UnsubscribeFromStream
  ]

  defmodule State do
    defstruct ~w(base_name credentials requests subscriptions pid_to_correlation_id read_only)a
  end

  def _name(base_name), do: Module.concat(base_name, RequestManager)

  def _process_supervisor_name(base_name),
    do: Module.concat(base_name, MessageProcessingSupervisor)

  def start_link(base_name, configuration),
    do: GenServer.start_link(__MODULE__, {base_name, configuration}, name: _name(base_name))

  def ping(base_name, correlation_id) do
    base_name
    |> _name()
    |> GenServer.call({:ping, correlation_id})
  end

  def execute(base_name, message, correlation_id, timeout \\ 5_000) do
    base_name
    |> _name()
    |> GenServer.call({:execute, correlation_id, message}, timeout)
  end

  def subscribe_to(base_name, stream, subscriber, resolve_link_tos, ack_timeout) do
    base_name
    |> _name()
    |> GenServer.call({:subscribe_to, stream, subscriber, resolve_link_tos, ack_timeout})
  end

  def read_and_stay_subscribed(base_name, subscriber, params) do
    base_name
    |> _name()
    |> GenServer.call({:read_and_stay_subscribed, subscriber, params})
  end

  def connect_to_persistent_subscription(
        base_name,
        subscriber,
        stream,
        group,
        allowed_in_flight_messages
      ) do
    base_name
    |> _name()
    |> GenServer.call(
      {:connect_to_persistent_subscription, subscriber, stream, group, allowed_in_flight_messages}
    )
  end

  def unregister_subscription(base_name, correlation_id) do
    base_name
    |> _name()
    |> GenServer.cast({:unregister_subscription, correlation_id})
  end

  ## Called only from `Connection`

  @doc """
  Send IdentifyClient message to EventStore. Called by `connection` process when connection is established.
  """
  def identify_client(connection_name, base_name) do
    base_name
    |> _name()
    |> GenServer.cast({:identify_client, connection_name})
  end

  @doc """
  Processes server message as soon as it is completely received via tcp.
  This function is run in `connection` process.
  """
  def process_server_message(base_name, message) do
    :ok =
      base_name
      |> _name()
      |> GenServer.cast({:process_server_message, message})
  end

  def kill_all_subscriptions(base_name) do
    base_name
    |> _name()
    |> GenServer.cast(:kill_all_subscriptions)
  end

  ## Server callbacks

  @impl GenServer
  def init({base_name, configuration}) do
    # link me with SubscriptionsSupervisor, since I'm subscription register.
    true =
      Extreme.SubscriptionsSupervisor._name(base_name)
      |> Process.whereis()
      |> Process.link()

    {:ok,
     %State{
       base_name: base_name,
       credentials: Configuration.prepare_credentials(configuration),
       requests: %{},
       subscriptions: %{},
       pid_to_correlation_id: %{},
       read_only: Keyword.get(configuration, :read_only, false)
     }}
  end

  @impl GenServer
  def handle_call({:ping, correlation_id}, from, %State{} = state) do
    state = %State{state | requests: Map.put(state.requests, correlation_id, from)}

    _in_task(state.base_name, fn ->
      {:ok, message} = Request.prepare(:ping, correlation_id)
      :ok = Connection.push(state.base_name, message)
    end)

    {:noreply, state}
  end

  def handle_call(
        {:execute, _correlation_id, %message_type{} = _message},
        _from,
        %State{read_only: true} = state
      )
      when message_type not in @read_only_message_types do
    {:reply, {:error, :read_only}, state}
  end

  def handle_call({:execute, correlation_id, message}, from, %State{} = state) do
    state = %State{state | requests: Map.put(state.requests, correlation_id, from)}

    _in_task(state.base_name, fn ->
      {:ok, message} = Request.prepare(message, state.credentials, correlation_id)

      :ok = Connection.push(state.base_name, message)
    end)

    {:noreply, state}
  end

  def handle_call(
        {:subscribe_to, stream, subscriber, resolve_link_tos, ack_timeout},
        from,
        %State{} = state
      ) do
    _start_subscription(self(), from, state.base_name, fn correlation_id ->
      Extreme.SubscriptionsSupervisor.start_subscription(
        state.base_name,
        correlation_id,
        subscriber,
        stream,
        resolve_link_tos,
        ack_timeout
      )
    end)

    {:noreply, state}
  end

  def handle_call({:read_and_stay_subscribed, subscriber, read_params}, from, %State{} = state) do
    _start_subscription(self(), from, state.base_name, fn correlation_id ->
      Extreme.SubscriptionsSupervisor.start_reading_subscription(
        state.base_name,
        correlation_id,
        subscriber,
        read_params
      )
    end)

    {:noreply, state}
  end

  def handle_call(
        {:connect_to_persistent_subscription, subscriber, stream, group,
         allowed_in_flight_messages},
        from,
        %State{} = state
      ) do
    _start_subscription(self(), from, state.base_name, fn correlation_id ->
      Extreme.SubscriptionsSupervisor.start_persistent_subscription(
        state.base_name,
        correlation_id,
        subscriber,
        stream,
        group,
        allowed_in_flight_messages
      )
    end)

    {:noreply, state}
  end

  defp _start_subscription(req_manager, from, base_name, fun) do
    _in_task(base_name, fn ->
      correlation_id = Tools.generate_uuid()

      GenServer.cast(req_manager, {:prepare_subscription, correlation_id})

      correlation_id
      |> fun.()
      |> case do
        {:ok, subscription} ->
          GenServer.cast(req_manager, {:confirm_subscription, correlation_id, subscription})
          GenServer.reply(from, {:ok, subscription})

        error ->
          :ok = GenServer.cast(req_manager, {:unregister_subscription, correlation_id})
          GenServer.reply(from, error)
      end
    end)
  end

  @impl GenServer
  def handle_cast({:execute, correlation_id, message}, %State{} = state) do
    _in_task(state.base_name, fn ->
      {:ok, message} = Request.prepare(message, state.credentials, correlation_id)
      :ok = Connection.push(state.base_name, message)
    end)

    {:noreply, state}
  end

  def handle_cast({:identify_client, connection_name}, %State{} = state) do
    {:ok, message} = Request.prepare(:identify_client, connection_name, state.credentials)
    :ok = Connection.push(state.base_name, message)
    {:noreply, state}
  end

  def handle_cast({:process_server_message, message}, %State{} = state) do
    correlation_id =
      message
      |> Response.get_correlation_id()

    %State{} =
      state =
      state.subscriptions[correlation_id]
      |> _process_server_message(message, state)

    {:noreply, state}
  end

  def handle_cast({:send_heartbeat_response, correlation_id}, %State{} = state) do
    {:ok, message} = Request.prepare(:heartbeat_response, correlation_id)
    :ok = Connection.push(state.base_name, message)
    {:noreply, state}
  end

  def handle_cast({:respond_with_server_message, correlation_id, response}, %State{} = state) do
    %State{} =
      state =
      state.requests
      |> Map.get(correlation_id)
      |> case do
        nil ->
          state

        from ->
          requests = Map.delete(state.requests, correlation_id)
          :ok = GenServer.reply(from, response)
          %{state | requests: requests}
      end

    {:noreply, state}
  end

  def handle_cast({:prepare_subscription, correlation_id}, %State{} = state) do
    subscriptions = Map.put(state.subscriptions, correlation_id, {:pending, correlation_id, []})

    {:noreply, %State{state | subscriptions: subscriptions}}
  end

  def handle_cast({:confirm_subscription, correlation_id, subscription}, %State{} = state) do
    Process.monitor(subscription)
    {:pending, ^correlation_id, buffer} = Map.get(state.subscriptions, correlation_id)

    buffer
    |> Enum.reverse()
    |> Enum.each(&GenServer.cast(subscription, {:process_push, fn -> Response.parse(&1) end}))

    subscriptions = Map.put(state.subscriptions, correlation_id, subscription)
    pid_to_correlation_id = Map.put(state.pid_to_correlation_id, subscription, correlation_id)

    {:noreply,
     %State{state | subscriptions: subscriptions, pid_to_correlation_id: pid_to_correlation_id}}
  end

  def handle_cast({:unregister_subscription, correlation_id}, %State{} = state) do
    {subscription, subscriptions} = Map.pop(state.subscriptions, correlation_id)
    pid_to_correlation_id = Map.delete(state.pid_to_correlation_id, subscription)
    SubscriptionsSupervisor.stop_subscription(state.base_name, subscription)
    requests = Map.delete(state.requests, correlation_id)

    state = %State{
      state
      | requests: requests,
        subscriptions: subscriptions,
        pid_to_correlation_id: pid_to_correlation_id
    }

    {:noreply, state}
  end

  def handle_cast(:kill_all_subscriptions, %State{} = state) do
    Logger.warning("[Extreme] Killing all subscriptions")

    state.base_name
    |> Extreme.SubscriptionsSupervisor.kill_all_subscriptions()

    {:noreply, %State{state | subscriptions: %{}, pid_to_correlation_id: %{}}}
  end

  @impl GenServer
  def handle_info({:DOWN, _, :process, pid, _reason}, state) do
    {correlation_id, pid_to_correlation_id} = Map.pop(state.pid_to_correlation_id, pid)
    subscriptions = Map.delete(state.subscriptions, correlation_id)
    requests = Map.delete(state.requests, correlation_id)

    state = %State{
      state
      | subscriptions: subscriptions,
        pid_to_correlation_id: pid_to_correlation_id,
        requests: requests
    }

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Extreme.RequestManager] Unhandled message received: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Helper functions

  defp _in_task(base_name, fun) do
    base_name
    |> _process_supervisor_name()
    |> Task.Supervisor.start_child(fun)
  end

  # we got message for still unregistered subscription so we need to buffer it
  defp _process_server_message(
         {:pending, correlation_id, buffer},
         <<0xC2, _auth, correlation_id::16-binary, _data::binary>> = message,
         %State{} = state
       ) do
    subscriptions =
      state.subscriptions
      |> Map.put(
        correlation_id,
        {:pending, correlation_id, [message | buffer]}
      )

    %State{state | subscriptions: subscriptions}
  end

  # message is response for new subscription request
  defp _process_server_message({:pending, _correlation_id, _buffer}, message, state),
    do: _process_response(message, state)

  # message is response to pending request
  defp _process_server_message(nil, message, state),
    do: _process_response(message, state)

  # message is for subscription, decoding needs to be done there so we keep the order of incoming messages
  defp _process_server_message(subscription, message, state) do
    GenServer.cast(subscription, {:process_push, fn -> Response.parse(message) end})
    state
  end

  defp _process_response(message, state) do
    _in_task(state.base_name, fn ->
      message
      |> Response.parse()
      |> _respond_on(state.base_name)
    end)

    state
  end

  defp _respond_on({:client_identified, _correlation_id}, _),
    do: :ok

  defp _respond_on({:heartbeat_request, correlation_id}, base_name),
    do: :ok = _send_heartbeat_response(base_name, correlation_id)

  defp _respond_on({:pong, correlation_id}, base_name),
    do: :ok = _respond_with_server_message(base_name, correlation_id, :pong)

  defp _respond_on({:error, :not_authenticated, correlation_id}, base_name),
    do:
      :ok = _respond_with_server_message(base_name, correlation_id, {:error, :not_authenticated})

  defp _respond_on({:error, :bad_request, correlation_id}, base_name),
    do: :ok = _respond_with_server_message(base_name, correlation_id, {:error, :bad_request})

  defp _respond_on({_auth, correlation_id, message}, base_name) do
    response = Response.reply(message, correlation_id)
    :ok = _respond_with_server_message(base_name, correlation_id, response)
  end

  # Sends `message` as a response to pending request or as a push on subscription.
  # `correlation_id` is used to find pending request/subscription.
  defp _respond_with_server_message(base_name, correlation_id, response) do
    base_name
    |> _name()
    |> GenServer.cast({:respond_with_server_message, correlation_id, response})
  end

  defp _send_heartbeat_response(base_name, correlation_id) do
    base_name
    |> _name()
    |> GenServer.cast({:send_heartbeat_response, correlation_id})
  end
end
