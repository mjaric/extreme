defmodule Extreme.EventProducer.Supervisor do
  use DynamicSupervisor
  alias Extreme.EventProducer

  def _name(base_name),
    do: Module.concat(base_name, EventProducerSupervisor)

  def start_link(base_name),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: _name(base_name))

  def init(:ok),
    do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_event_producer(base_name :: module(), opts :: Keyword.t()) ::
          Supervisor.on_start_child()
  def start_event_producer(base_name, opts) do
    base_name
    |> _name()
    |> DynamicSupervisor.start_child(%{
      id: EventProducer,
      start: {EventProducer, :start_link, [base_name, opts]},
      restart: :transient
    })
  end
end
