defmodule EstoqueOS.Inventory.BoxSuggestionTest do
  @moduledoc """
  When a delivery lands, the question is not "which boxes exist" — it is "where
  does this belong". A warehouse organised by whoever was holding the scanner is
  a warehouse where finding anything means opening everything.

  Every suggestion carries its reason. A list of box codes with no explanation is
  a list nobody trusts enough to follow.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Catalog
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    {:ok, group} = Catalog.create_product_group(%{name: "Gazes"})

    gauze =
      product_fixture(%{
        name: "Gaze estéril 7,5",
        product_group_id: group.id,
        sector: "ENFERMAGEM"
      })

    other_gauze =
      product_fixture(%{
        name: "Gaze estéril 10",
        product_group_id: group.id,
        sector: "ENFERMAGEM"
      })

    drug = product_fixture(%{name: "Cetamina 50mg", sector: "ANESTESIA - MEDICAMENTOS"})
    swab = product_fixture(%{name: "Swab", sector: "ENFERMAGEM"})

    put = fn product, box ->
      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-01-31]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              # The box's own location, so the fixture never invents stock that
              # is in a box in one place and at a location in another.
              location_id: box.location_id,
              box_id: box.id,
              quantity: Decimal.new(10)
            }
          ]
        })
    end

    %{
      warehouse: warehouse,
      gauze: gauze,
      other_gauze: other_gauze,
      drug: drug,
      swab: swab,
      put: put
    }
  end

  test "puts the box that already holds this product first", context do
    %{warehouse: warehouse, gauze: gauze, other_gauze: other, swab: swab, put: put} = context

    same = box_fixture(%{code: "SM01", location_id: warehouse.id})
    group_box = box_fixture(%{code: "GR01", location_id: warehouse.id})
    sector_box = box_fixture(%{code: "SC01", location_id: warehouse.id})

    put.(gauze, same)
    put.(other, group_box)
    put.(swab, sector_box)

    assert [first, second, third] = Locations.suggest_boxes(gauze.id, warehouse.id)

    # Splitting one product across two boxes is how a recall finds half of it.
    assert first.box.code == "SM01"
    assert first.reason == :same_product
    assert second.box.code == "GR01"
    assert second.reason == :same_group
    assert third.box.code == "SC01"
    assert third.reason == :same_sector
  end

  test "says why, not just where", context do
    %{warehouse: warehouse, gauze: gauze, other_gauze: other, put: put} = context
    box = box_fixture(%{code: "WH01", location_id: warehouse.id})
    put.(other, box)

    assert [suggestion] = Locations.suggest_boxes(gauze.id, warehouse.id)
    assert suggestion.because == "Gaze estéril 10"
  end

  test "offers nothing when no box has anything related", context do
    %{warehouse: warehouse, gauze: gauze, drug: drug, put: put} = context
    box = box_fixture(%{code: "UN01", location_id: warehouse.id})
    put.(drug, box)

    # A suggestion with no reason is noise, and noise is what makes people stop
    # reading suggestions.
    assert Locations.suggest_boxes(gauze.id, warehouse.id) == []
  end

  test "ignores boxes at another location", context do
    %{gauze: gauze, put: put} = context
    elsewhere = location_fixture(%{name: "Escritório SP", kind: "warehouse"})
    far = box_fixture(%{code: "FR01", location_id: elsewhere.id})
    put.(gauze, far)

    assert Locations.suggest_boxes(gauze.id, context.warehouse.id) == []
  end

  test "ignores an empty box", context do
    %{warehouse: warehouse, gauze: gauze} = context
    _empty = box_fixture(%{code: "EM01", location_id: warehouse.id})

    assert Locations.suggest_boxes(gauze.id, warehouse.id) == []
  end

  test "offers at most a handful", context do
    %{warehouse: warehouse, gauze: gauze, other_gauze: other, put: put} = context

    for n <- 1..6 do
      put.(other, box_fixture(%{code: "MN0#{n}", location_id: warehouse.id}))
    end

    assert length(Locations.suggest_boxes(gauze.id, warehouse.id)) == 3
    assert length(Locations.suggest_boxes(gauze.id, warehouse.id, limit: 5)) == 5
  end
end
