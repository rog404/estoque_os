defmodule EstoqueOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :estoque_os,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Consolidation is a release-time optimisation. Leaving it on while
      # developing means any partial recompile of a schema with `redact: true`
      # fields — Ecto derives an `Inspect` implementation for those — warns that
      # the protocol was already consolidated, and `precommit` turns that
      # warning into a failed build. Prod still gets the fast dispatch.
      consolidate_protocols: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
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

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
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
      {:phoenix_live_dashboard, "~> 0.8.3"},
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
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # The ledger is UTC throughout — the one timezone with no ambiguity to
      # store. This is what turns it back into a wall clock in São Paulo when
      # a screen renders it. Bundles its own release, no hackney/HTTP
      # dependency to clash with — `tzdata` pulled in an `idna` version this
      # app's other deps had already moved past.
      {:tz, "~> 0.28"},
      # Sobelow reads the router and the LiveViews for the class of mistake that
      # is invisible in review: a write reachable without the role it needs, a
      # parameter that reaches a query, a missing CSRF. Credo keeps the style
      # arguments out of the diff.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
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
      # Extract before the tests rather than checking: `--check-up-to-date` also
      # fails when `format` merely moves a `gettext(...)` call to a new line, and
      # a gate that cries wolf gets ignored. Merging instead pulls any new string
      # into the .po with an empty translation, where gettext_test.exs fails on
      # it by name — so a string that was never extracted still cannot ship, and
      # nobody is nagged about line numbers.
      precommit: [
        # Advisories published since the lockfile was written. First, because it
        # is the one failure no amount of local green can tell you about.
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
