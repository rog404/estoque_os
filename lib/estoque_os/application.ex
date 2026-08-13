defmodule EstoqueOS.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
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
      # Start a worker by calling: EstoqueOS.Worker.start_link(arg)
      # {EstoqueOS.Worker, arg},
      # Start to serve requests, typically the last entry
      EstoqueOSWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EstoqueOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EstoqueOSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
