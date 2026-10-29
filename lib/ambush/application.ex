defmodule Ambush.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{DynamicSupervisor, name: Ambush.Supervisor, strategy: :one_for_one}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Ambush.ApplicationSupervisor)
  end
end
