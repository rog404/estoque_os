defmodule EstoqueOS.KitsQueryCountTest do
  @moduledoc """
  Guards `Kits.availability/2` against an N+1, which a test that only checks
  the answer cannot see, so this counts the queries.
  """

  use EstoqueOS.DataCase, async: false

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Kits

  defp count_queries(fun) do
    parent = self()
    handler = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler,
      [:estoque_os, :repo, :query],
      fn _event, _measure, _meta, _config -> send(parent, :query) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain = fn drain, n ->
      receive do
        :query -> drain.(drain, n + 1)
      after
        0 -> n
      end
    end

    drain.(drain, 0)
  end

  test "reads a kit's availability without a query per component" do
    warehouse = location_fixture(%{name: "Estoque Principal"})

    items =
      for n <- 1..12 do
        product = product_fixture(%{name: "Componente #{n}"})
        %{description: "Componente #{n}", quantity: Decimal.new(1), product_id: product.id}
      end

    {:ok, small} =
      Kits.create_kit(%{name: "Kit pequeno", items: Enum.take(items, 2)})

    {:ok, large} = Kits.create_kit(%{name: "Kit grande", items: items})

    small_kit = Kits.get_kit!(small.id)
    large_kit = Kits.get_kit!(large.id)

    two_lines = count_queries(fn -> Kits.availability(small_kit, warehouse.id) end)
    twelve_lines = count_queries(fn -> Kits.availability(large_kit, warehouse.id) end)

    assert twelve_lines == two_lines,
           "#{two_lines} queries for 2 components, #{twelve_lines} for 12"
  end
end
