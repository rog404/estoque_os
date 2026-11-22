defmodule EstoqueOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :estoque_os,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Prod-only: in dev, recompiling a schema with `redact: true` fields warns
      # that the Inspect protocol was already consolidated, which fails precommit.
      consolidate_protocols: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {EstoqueOS.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Builds the digested assets as a release step, so `MIX_ENV=prod mix release`
  # yields a complete servable release with no separate Node build.
  defp releases do
    [
      estoque_os: [
        steps: [&build_assets/1, :assemble, :tar],
        include_executables_for: [:unix]
      ]
    ]
  end

  defp build_assets(release) do
    Mix.Task.run("assets.setup")
    Mix.Task.run("assets.deploy")
    release
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:sweet_xml, "~> 0.7"},
      {:elixlsx, "~> 0.6"},
      {:xlsx_reader, "~> 0.8"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.5"},
      # Renders the UTC ledger as São Paulo wall-clock time. `tz` over `tzdata`:
      # tzdata pulled an `idna` version that clashed with other deps.
      {:tz, "~> 0.28"},
      # Scans for security mistakes invisible in review: a write missing its role
      # gate, params reaching a query, a missing CSRF.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # The scenario the six form screens are tested against. Separate from
      # `seeds.exs`, which loads real data a fresh install genuinely needs.
      "dev.seeds": ["run priv/repo/dev_seeds.exs"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind estoque_os", "esbuild estoque_os"],
      "assets.deploy": [
        "tailwind estoque_os --minify",
        "esbuild estoque_os --minify",
        "phx.digest"
      ],
      # Merge (not --check-up-to-date): extraction pulls new strings into the .po
      # empty, where gettext_test.exs fails on them by name, without nagging over
      # line moves.
      precommit: [
        # Advisories published since the lockfile was written.
        "hex.audit",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "gettext.extract --merge",
        "credo",
        "sobelow",
        "test"
      ]
    ]
  end
end
