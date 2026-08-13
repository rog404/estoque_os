defmodule EstoqueOS.KitsTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits, Outbound}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    gown = product_fixture(%{name: "Avental EG"})
    pen = product_fixture(%{name: "Caneta de eletrocautério"})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit Paciente",
        items: [
          %{description: "Avental EG", quantity: Decimal.new(4), product_id: gown.id},
          %{description: "Caneta de eletrocautério", quantity: Decimal.new(1), product_id: pen.id}
        ]
      })

    gown_lot = lot_fixture(%{product_id: gown.id, expires_on: ~D[2028-01-31]})
    pen_lot = lot_fixture(%{product_id: pen.id, expires_on: ~D[2028-01-31]})

    stock_in(gown_lot, warehouse, 40)
    stock_in(pen_lot, warehouse, 6)

    %{
      warehouse: warehouse,
      kit: Kits.get_kit!(kit.id),
      gown: gown,
      pen: pen,
      gown_lot: gown_lot,
      pen_lot: pen_lot
    }
  end

  defp stock_in(lot, location, quantity, opts \\ []) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  describe "create_kit/1" do
    test "provisions a product for the kit, so it can be searched and issued like one",
         %{kit: kit} do
      assert kit.product
      assert kit.product.name == kit.name
      assert kit.product.stock_unit == "KIT"
      assert kit.product.kit_id == kit.id
    end
  end

  describe "update_kit/2" do
    test "renames the kit's product along with the kit", %{kit: kit} do
      assert {:ok, renamed} = Kits.update_kit(kit, %{name: "Kit Paciente v2"})

      assert renamed.name == "Kit Paciente v2"
      assert renamed.product.name == "Kit Paciente v2"
    end
  end

  describe "availability/2" do
    test "answers how many kits the stock covers and what runs out first", %{
      kit: kit,
      warehouse: warehouse,
      pen: pen
    } do
      # 40 gowns cover 10 kits; 6 pens cover only 6.
      availability = Kits.availability(kit, warehouse.id)

      assert Decimal.equal?(availability.possible, Decimal.new(6))
      assert [bottleneck] = availability.bottlenecks
      assert bottleneck.item.product_id == pen.id
    end

    test "counts zero when a component is missing entirely", %{kit: kit} do
      empty = location_fixture(%{name: "Missão vazia", kind: "mission_site"})

      assert Decimal.equal?(Kits.availability(kit, empty.id).possible, Decimal.new(0))
    end

    test "reports lines nobody resolved", %{kit: kit, warehouse: warehouse} do
      {:ok, unresolved} =
        Kits.create_kit(%{
          name: "Kit Anestesia",
          items: [%{description: "Cânula guedel 0", quantity: Decimal.new(2)}]
        })

      availability = Kits.availability(Kits.get_kit!(unresolved.id), warehouse.id)

      assert length(availability.unresolved) == 1
      assert Kits.unresolved_items(kit) == []
    end
  end

  describe "box_breakdown/2" do
    test "lists where each resolved component is, box by box and loose", %{
      kit: kit,
      warehouse: warehouse,
      gown: gown,
      pen_lot: pen_lot
    } do
      box = box_fixture(%{location_id: warehouse.id})
      stock_in(pen_lot, warehouse, 3, box_id: box.id)

      breakdown = Kits.box_breakdown(kit, warehouse.id)

      gown_item = Enum.find(kit.items, &(&1.product_id == gown.id))
      pen_item = Enum.find(kit.items, &(&1.product_id != gown.id))

      gown_boxes = Map.fetch!(breakdown, gown_item.id)
      assert [%{box_code: nil, quantity: quantity}] = gown_boxes
      assert Decimal.equal?(quantity, Decimal.new(40))

      pen_boxes = Map.fetch!(breakdown, pen_item.id) |> Enum.sort_by(& &1.box_code)
      assert [%{box_code: nil, quantity: loose}, %{box_code: code, quantity: boxed}] = pen_boxes
      assert Decimal.equal?(loose, Decimal.new(6))
      assert code == box.code
      assert Decimal.equal?(boxed, Decimal.new(3))
    end

    test "leaves out a component nobody resolved", %{warehouse: warehouse} do
      {:ok, unresolved} =
        Kits.create_kit(%{
          name: "Kit Anestesia",
          items: [%{description: "Cânula guedel 0", quantity: Decimal.new(2)}]
        })

      breakdown = Kits.box_breakdown(Kits.get_kit!(unresolved.id), warehouse.id)

      assert breakdown == %{}
    end
  end

  describe "assemble/3" do
    test "converts the components into a new lot of the kit's own product", %{
      kit: kit,
      warehouse: warehouse,
      gown_lot: gown_lot,
      pen_lot: pen_lot
    } do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:ok, %{lot: lot, quantity: quantity}} =
               Kits.assemble(kit, 2, %{
                 location_id: warehouse.id,
                 box_id: box.id,
                 user_id: actor_id()
               })

      assert Decimal.equal?(quantity, Decimal.new(2))
      assert lot.product_id == kit.product.id

      # The kit's own product now sits in the box, 2 of it.
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(2))
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, box_id: box.id), Decimal.new(2))

      # 2 kits: 8 gowns and 2 pens left stock for good.
      assert Decimal.equal?(Inventory.balance(lot_id: gown_lot.id), Decimal.new(32))
      assert Decimal.equal?(Inventory.balance(lot_id: pen_lot.id), Decimal.new(4))
    end

    test "the new lot's expiry is the earliest among the components consumed", %{
      kit: kit,
      warehouse: warehouse,
      gown: gown
    } do
      sooner = lot_fixture(%{product_id: gown.id, expires_on: ~D[2026-09-30]})
      stock_in(sooner, warehouse, 40)

      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:ok, %{lot: lot}} =
               Kits.assemble(kit, 1, %{
                 location_id: warehouse.id,
                 box_id: box.id,
                 user_id: actor_id()
               })

      assert lot.expires_on == ~D[2026-09-30]
    end

    test "records which component lots built the new kit lot", %{
      kit: kit,
      warehouse: warehouse,
      gown_lot: gown_lot,
      pen_lot: pen_lot
    } do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:ok, %{lot: lot}} =
               Kits.assemble(kit, 2, %{
                 location_id: warehouse.id,
                 box_id: box.id,
                 user_id: actor_id()
               })

      provenance =
        EstoqueOS.Kits.KitLotProvenance
        |> EstoqueOS.Repo.all()
        |> Enum.filter(&(&1.kit_lot_id == lot.id))
        |> Map.new(&{&1.component_lot_id, &1.quantity})

      assert Decimal.equal?(Map.fetch!(provenance, gown_lot.id), Decimal.new(8))
      assert Decimal.equal?(Map.fetch!(provenance, pen_lot.id), Decimal.new(2))
    end

    test "draws from an ordinary box, and from loose stock, oldest expiry first", %{
      kit: kit,
      warehouse: warehouse,
      gown: gown,
      pen: pen
    } do
      storage = box_fixture(%{code: "ORG1", location_id: warehouse.id})
      stock_in(lot_fixture(%{product_id: gown.id}), warehouse, 60, box_id: storage.id)
      stock_in(lot_fixture(%{product_id: pen.id}), warehouse, 10, box_id: storage.id)

      target = box_fixture(%{code: "KTK9", location_id: warehouse.id})

      assert {:ok, %{quantity: quantity}} =
               Kits.assemble(kit, 10, %{
                 location_id: warehouse.id,
                 box_id: target.id,
                 user_id: actor_id()
               })

      assert Decimal.equal?(quantity, Decimal.new(10))
      # The storage box was drawn from, so it is lighter than it started.
      assert Decimal.compare(Inventory.balance(box_id: storage.id), Decimal.new(70)) == :lt
    end

    test "refuses when a component runs short, naming it", %{
      kit: kit,
      warehouse: warehouse,
      pen: pen
    } do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:error, {:insufficient_stock, %{item: item, missing: missing}}} =
               Kits.assemble(kit, 10, %{
                 location_id: warehouse.id,
                 box_id: box.id,
                 user_id: actor_id()
               })

      assert item.product_id == pen.id
      assert Decimal.equal?(missing, Decimal.new(4))

      # Nothing was converted.
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(46))
    end

    test "with allow_partial, builds as many whole kits as it can and says what stopped the rest",
         %{kit: kit, warehouse: warehouse, pen: pen} do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:ok, %{quantity: built, requested: requested, bottleneck: item}} =
               Kits.assemble(kit, 10, %{
                 location_id: warehouse.id,
                 box_id: box.id,
                 user_id: actor_id(),
                 allow_partial: true
               })

      # 6 pens is the bottleneck: only 6 whole kits can be built.
      assert Decimal.equal?(built, Decimal.new(6))
      assert Decimal.equal?(requested, Decimal.new(10))
      assert item.product_id == pen.id
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(6))
    end

    test "refuses a kit with an unresolved component", %{warehouse: warehouse} do
      {:ok, kit} =
        Kits.create_kit(%{
          name: "Kit Enfermagem",
          items: [%{description: "Atadura elástica", quantity: Decimal.new(2)}]
        })

      box = box_fixture(%{code: "KTK2", location_id: warehouse.id})

      assert {:error, {:unresolved_items, [item]}} =
               Kits.assemble(Kits.get_kit!(kit.id), 1, %{
                 location_id: warehouse.id,
                 box_id: box.id
               })

      assert item.description == "Atadura elástica"
    end

    test "refuses a quantity of zero", %{kit: kit, warehouse: warehouse} do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      assert {:error, :invalid_quantity} =
               Kits.assemble(kit, 0, %{location_id: warehouse.id, box_id: box.id})
    end
  end

  describe "assembled_count/1" do
    test "is the kit product's balance across every location", %{
      kit: kit,
      warehouse: warehouse
    } do
      other = location_fixture(%{name: "Trânsito", kind: "warehouse"})
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})
      other_box = box_fixture(%{code: "KTK2", location_id: other.id})

      stock_in(lot_fixture(%{product_id: kit.product.id}), other, 3, box_id: other_box.id)

      {:ok, _} =
        Kits.assemble(kit, 2, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

      assert Decimal.equal?(Kits.assembled_count(kit), Decimal.new(5))
    end
  end

  describe "a kit, once assembled, is a product like any other" do
    test "can be found and written off through Outbound.issue_many/2, no kit code involved",
         %{kit: kit, warehouse: warehouse} do
      box = box_fixture(%{code: "KTK1", location_id: warehouse.id})

      {:ok, _} =
        Kits.assemble(kit, 3, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

      assert {:ok, transaction} =
               Outbound.issue_many([%{product_id: kit.product.id, quantity: Decimal.new(2)}], %{
                 location_id: warehouse.id,
                 user_id: actor_id()
               })

      assert transaction.type == "manual_out"
      assert Decimal.equal?(Inventory.balance(product_id: kit.product.id), Decimal.new(1))
    end
  end
end
