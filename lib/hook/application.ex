defmodule Hook.Application do
  @moduledoc false

  use Application
  alias Hook.Server

  @impl Application
  def start(_type, _args) do
    children = [Server]
    Supervisor.start_link(children, strategy: :one_for_one, name: Hook.Supervisor)
  end
end
