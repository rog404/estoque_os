defmodule EstoqueOS.Release do
  @moduledoc """
  Tasks that need to run inside a release, where Mix is not available.

  Called by name from the release binary — see `rel/overlays/Procfile`, which
  migrates before the web server starts.
  """

  @app :estoque_os

  @doc """
  Runs every pending migration.

  Starts the repository with a pool of two: the free-tier database allows two
  connections in total, and waiting on the web server would deadlock the deploy.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls the given repository back to `version`. Not part of any deploy.
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

  @doc """
  Loads the catalog and the demo scenario, but only into a database that has
  nobody in it yet.

  Exists because free plans give no shell to run `seed/0`. Guarded twice: only
  when `SEED_ON_EMPTY` is set and the `users` table is empty (once, on first
  boot); afterwards it costs one `SELECT` per boot.
  """
  def seed_if_empty do
    load_app()

    if System.get_env("SEED_ON_EMPTY") in ~w(true 1) do
      for repo <- repos() do
        {:ok, seeded?, _} = Ecto.Migrator.with_repo(repo, &seed_empty_repo/1)

        if seeded? do
          IO.puts("[seed] fresh database — bootstrap data loaded")
        else
          IO.puts("[seed] database already has accounts — nothing to do")
        end
      end
    end
  end

  # From-zero loads only the bootstrap, since stock arrives by import; the demo
  # scenario is opt-in via `SEED_DEMO`.
  defp seed_empty_repo(repo) do
    if repo.aggregate(EstoqueOS.Accounts.User, :count) == 0 do
      EstoqueOS.Seeds.bootstrap()

      if System.get_env("SEED_DEMO") in ~w(true 1) do
        EstoqueOS.Seeds.run()
        EstoqueOS.DemoData.run!()
      end

      true
    else
      false
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
