# Starting data for a fresh installation:
#
#     mix run priv/repo/seeds.exs
#
# Reads the spreadsheets in `priv/samples/` — the standard supply table and the
# mission kits. Safe to run more than once. `EstoqueOS.Release.seed/0` is the
# same thing from inside a release.

result = EstoqueOS.Seeds.run()

IO.puts("""
Seeds carregadas:
  locais:   #{length(result.locations)}
  produtos: #{length(result.products)}
  kits:     #{length(result.kits)}
""")
