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

  @doc """
  Loads the catalog and the demo scenario, but only into a database that has
  nobody in it yet.

  This exists because the free plans these demos run on do not give you a
  shell. Without it there is no way to run `seed/0` on the server, and the
  deployment comes up correct and empty — which for a demo is the same as
  broken.

  Guarded twice, so it cannot become a surprise. It runs only when
  `SEED_ON_EMPTY` is set, and only when the `users` table is empty — which is
  true exactly once, on the first boot against a fresh database. After that it
  costs one `SELECT` per boot, which matters on a plan where the service sleeps
  and wakes all day.
  """
  def seed_if_empty do
    load_app()

    if System.get_env("SEED_ON_EMPTY") in ~w(true 1) do
      for repo <- repos() do
        {:ok, seeded?, _} = Ecto.Migrator.with_repo(repo, &seed_empty_repo/1)

        if seeded? do
          IO.puts("[seed] fresh database — catalog and demo scenario loaded")
        else
          IO.puts("[seed] database already has accounts — nothing to do")
        end
      end
    end
  end

  defp seed_empty_repo(repo) do
    if repo.aggregate(EstoqueOS.Accounts.User, :count) == 0 do
      EstoqueOS.Seeds.run()
      EstoqueOS.DemoData.run!()
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
