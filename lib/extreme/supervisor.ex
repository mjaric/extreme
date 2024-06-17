defmodule Extreme.Supervisor do
  use Supervisor

  def start_link(base_name, configuration),
    do: Supervisor.start_link(__MODULE__, {base_name, configuration}, name: _name(base_name))

  @impl true
  def init({base_name, configuration}) do
    [
      {Extreme.SubscriptionsSupervisor, base_name},
      {Extreme.EventProducer.Supervisor, base_name},
      {Task.Supervisor, [name: Extreme.RequestManager._process_supervisor_name(base_name)]},
      %{
        id: RequestManager,
        start: {Extreme.RequestManager, :start_link, [base_name, configuration]}
      },
      %{
        id: Connection,
        start: {Extreme.Connection, :start_link, [base_name, configuration]}
      }
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp _name(base_name), do: Module.concat(base_name, Supervisor)
end
