defmodule EstoqueOS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EstoqueOSWeb.Telemetry,
      EstoqueOS.Repo,
      EstoqueOS.Accounts.LoginThrottle,
      {DNSCluster, query: Application.get_env(:estoque_os, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EstoqueOS.PubSub},
      EstoqueOSWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: EstoqueOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    EstoqueOSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
