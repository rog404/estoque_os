defmodule EstoqueOS.Release do
  @moduledoc """
  Tasks that need to run inside a release, where Mix is not available.

  Called by name from the release binary — see `rel/overlays/Procfile`, which
  migrates before the web server starts.
  """

  @app :estoque_os

  @doc """
  Runs every pending migration.

  Starts the repository on its own, with a pool of two: the free-tier database
  allows two connections in total, and a migration that has to wait for the
  running web server to hand one back would deadlock the deploy.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls the given repository back to `version`. Not part of any deploy — it is
  here because the alternative, at the moment it is needed, is `psql`.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Loads the starting data a fresh installation needs: the locations, the
  standard supply table as the product catalog, and the mission kits. Safe to
  run more than once — existing rows are left alone.

      bin/estoque_os eval "EstoqueOS.Release.seed()"
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, result, _} = Ecto.Migrator.with_repo(repo, fn _repo -> EstoqueOS.Seeds.run() end)

      IO.puts("""
      Seeds carregadas:
        locais:   #{length(result.locations)}
        produtos: #{length(result.products)}
        kits:     #{length(result.kits)}
      """)
    end
  end

  @doc """
  Loads the demo scenario on top of the catalog: boxes, stock with lots, two
  invoices, assembled kits and a mission under way. Refuses to run twice.

      bin/estoque_os eval "EstoqueOS.Release.demo()"
  """
  def demo do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> EstoqueOS.DemoData.run!() end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
