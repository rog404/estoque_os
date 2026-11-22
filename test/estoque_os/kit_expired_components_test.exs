defmodule EstoqueOS.KitExpiredComponentsTest do
  @moduledoc """
  A kit is sealed, and FEFO would reach for the expired lot first. So assembly is
  refused while any component has expired stock at the location, with no
  override: the remedy is a write-off, which leaves a record. FEFO is unchanged
  everywhere else.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Kits
  alias EstoqueOS.Outbound

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "KX01", location_id: warehouse.id})

    gauze = product_fixture(%{name: "Compressa de gaze"})
    tape = product_fixture(%{name: "Fita microporosa"})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit enfermagem",
        items: [
          %{description: "Compressa de gaze", quantity: Decimal.new(10), product_id: gauze.id},
          %{description: "Fita microporosa", quantity: Decimal.new(2), product_id: tape.id}
        ]
      })

    %{
      warehouse: warehouse,
      box: box,
      kit: Kits.get_kit!(kit.id),
      gauze: gauze,
      tape: tape
    }
  end

  defp stock(lot, location, quantity, box) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: EstoqueOS.AccountsFixtures.user_fixture().id,
        occurred_at: DateTime.utc_now(:second),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: box.id,
            quantity: quantity,
            unit_cost: Decimal.new("1.00")
          }
        ]
      })
  end

  defp assemble(kit, quantity, %{warehouse: warehouse, box: box}) do
    Kits.assemble(kit, quantity, %{
      location_id: warehouse.id,
      box_id: box.id,
      user_id: EstoqueOS.AccountsFixtures.user_fixture().id
    })
  end

  describe "with nothing expired" do
    setup ctx do
      good_until = Date.add(Date.utc_today(), 400)
      gauze_lot = lot_fixture(%{product_id: ctx.gauze.id, expires_on: good_until})
      tape_lot = lot_fixture(%{product_id: ctx.tape.id, expires_on: good_until})
      stock(gauze_lot, ctx.warehouse, 500, ctx.box)
      stock(tape_lot, ctx.warehouse, 100, ctx.box)
      %{good_until: good_until}
    end

    test "it assembles", ctx do
      assert {:ok, %{quantity: quantity}} = assemble(ctx.kit, 5, ctx)
      assert Decimal.equal?(quantity, 5)
    end

    test "availability reports nothing expired", ctx do
      availability = Kits.availability(ctx.kit, ctx.warehouse.id)

      assert availability.expired_components == []
      assert Enum.all?(availability.lines, &is_nil(&1.expired))
    end
  end

  describe "with one component expired" do
    setup ctx do
      expired_on = Date.add(Date.utc_today(), -5)
      good_until = Date.add(Date.utc_today(), 400)

      expired_lot = lot_fixture(%{product_id: ctx.gauze.id, expires_on: expired_on})
      fresh_lot = lot_fixture(%{product_id: ctx.gauze.id, expires_on: good_until})
      tape_lot = lot_fixture(%{product_id: ctx.tape.id, expires_on: good_until})

      # Plenty of good gauze too: the refusal is about the expired stock, not shortage.
      stock(expired_lot, ctx.warehouse, 30, ctx.box)
      stock(fresh_lot, ctx.warehouse, 500, ctx.box)
      stock(tape_lot, ctx.warehouse, 100, ctx.box)

      %{expired_lot: expired_lot, expired_on: expired_on, fresh_lot: fresh_lot}
    end

    test "assembly is refused, and says which component and from when", ctx do
      assert {:error, {:expired_components, [line]}} = assemble(ctx.kit, 1, ctx)

      assert line.item.description == "Compressa de gaze"
      assert Decimal.equal?(line.expired.quantity, 30)
      assert line.expired.earliest_expiry == ctx.expired_on
    end

    test "there is no override", ctx do
      assert {:error, {:expired_components, _}} =
               Kits.assemble(ctx.kit, 1, %{
                 location_id: ctx.warehouse.id,
                 box_id: ctx.box.id,
                 user_id: EstoqueOS.AccountsFixtures.user_fixture().id,
                 allow_partial: true,
                 allow_expired: true
               })
    end

    test "availability names it, so a screen can refuse before the button", ctx do
      availability = Kits.availability(ctx.kit, ctx.warehouse.id)

      assert [line] = availability.expired_components
      assert line.item.product_id == ctx.gauze.id
    end

    test "writing the expired stock off unblocks assembly", ctx do
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "adjustment",
          reason_code: "expiry",
          user_id: EstoqueOS.AccountsFixtures.user_fixture().id,
          occurred_at: DateTime.utc_now(:second),
          notes: "Baixa de lote vencido",
          entries: [
            %{
              lot_id: ctx.expired_lot.id,
              location_id: ctx.warehouse.id,
              box_id: ctx.box.id,
              quantity: Decimal.new(-30)
            }
          ]
        })

      assert Kits.availability(ctx.kit, ctx.warehouse.id).expired_components == []
      assert {:ok, %{quantity: _}} = assemble(ctx.kit, 5, ctx)
    end

    # Only kits refuse expired stock; everything else draws oldest-first.
    test "issuing still picks the expired lot first", ctx do
      user = EstoqueOS.AccountsFixtures.user_fixture()

      assert {:ok, _} =
               Outbound.issue(ctx.gauze.id, 10, %{
                 location_id: ctx.warehouse.id,
                 user_id: user.id,
                 destination: "operating_room"
               })

      assert Decimal.equal?(
               Inventory.balance(lot_id: ctx.expired_lot.id, location_id: ctx.warehouse.id),
               20
             )
    end
  end

  # A component can expire after it is sealed in; the kit lot's expiry is the
  # date the first one does.
  describe "a kit already assembled" do
    test "carries the earliest expiry of what went into it", ctx do
      soon = Date.add(Date.utc_today(), 20)
      later = Date.add(Date.utc_today(), 400)

      gauze_lot = lot_fixture(%{product_id: ctx.gauze.id, expires_on: soon})
      tape_lot = lot_fixture(%{product_id: ctx.tape.id, expires_on: later})
      stock(gauze_lot, ctx.warehouse, 500, ctx.box)
      stock(tape_lot, ctx.warehouse, 100, ctx.box)

      assert {:ok, %{lot: kit_lot}} = assemble(ctx.kit, 3, ctx)

      assert kit_lot.expires_on == soon
    end
  end
end
