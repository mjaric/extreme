defmodule Extreme.ConnectionImpl do
  @moduledoc """
  Set of connection related functions meant to be used from `Extreme.Connection` only!
  """
  alias Extreme.RequestManager
  alias Extreme.Connection.State

  require Logger

  def execute(message, %State{socket: socket}),
    do: :gen_tcp.send(socket, message)

  def receive_package(pkg, %State{socket: socket, received_data: received_data} = state) do
    :inet.setopts(socket, active: :once)
    state = _process_package(received_data <> pkg, state)
    {:ok, state}
  end

  defp _process_package(
         <<message_length::32-unsigned-little-integer, content::binary-size(message_length),
           rest::binary>>,
         %State{} = state
       ) do
    # Handle binary data containing zero, one or many messages
    # All messages start with a 32 bit unsigned little endian integer of the content length + a binary body of that size
    :ok = RequestManager.process_server_message(state.base_name, content)
    _process_package(rest, state)
  end

  # No full message left, keep state in GenServer to reprocess once more data arrives
  defp _process_package(package_with_incomplete_message, %State{} = state),
    do: %{state | received_data: package_with_incomplete_message}
end
