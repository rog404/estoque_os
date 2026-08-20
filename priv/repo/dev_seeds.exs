# The demo and development scenario, on top of the real catalog.
#
#     mix ecto.reset && mix dev.seeds
#
# `seeds.exs` loads the truth a fresh install has: the locations, the 322 lines
# of the standard supply table, and the five kits. It creates no stock, which is
# correct — a new install has none.
#
# Everything the scenario builds, and why each piece is there, is in
# `EstoqueOS.DemoData`. It lives in `lib/` rather than here because the demo
# deployment has to run it too, where there is no checkout and no `mix` — see
# `EstoqueOS.Release.demo/0`. One definition, two callers.

EstoqueOS.DemoData.run!()
