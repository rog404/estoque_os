# Starting data for a fresh installation:
#
#     mix run priv/repo/seeds.exs
#
# Reads the real spreadsheets in samples/ — the OSI standard supply table and
# the mission kits. Safe to run more than once.

result = EstoqueOS.Seeds.run()

IO.puts("""
Seeds carregadas:
  locais:   #{length(result.locations)}
  produtos: #{length(result.products)}
  kits:     #{length(result.kits)}
""")
