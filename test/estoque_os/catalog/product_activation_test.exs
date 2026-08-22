defmodule EstoqueOS.Catalog.ProductActivationTest do
  @moduledoc """
  Taking a product out of the catalog, and putting it back.

  The catalog carries 322 products and the operation uses a fraction of them; a
  product nobody stocks any more is a wrong answer waiting in every picker. The
  flag that hides it already existed and every query already asked for it — what
  did not exist was the way to set it, or the record of who did.

  Nothing is deleted. The two facts these tests hold are that the history keeps
  naming a retired product, and that a product still sitting on a shelf cannot
  be hidden from the screens somebody would use to find it.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Catalog
  alias EstoqueOS.Catalog.ProductChange
  alias EstoqueOS.Inventory

  setup do
    warehouse = location_fixture(%{name: "Principal", kind: "warehouse"})
    box = box_fixture(%{code: "PR01", location_id: warehouse.id})
    product = product_fixture(%{name: "Gaze estéril"})
    lot = lot_fixture(%{product_id: product.id, lot_number: "L-1"})

    %{warehouse: warehouse, box: box, product: product, lot: lot}
  end

  defp receive_stock(ctx, quantity) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: ctx.lot.id,
            location_id: ctx.warehouse.id,
            box_id: ctx.box.id,
            quantity: Decimal.new(quantity),
            unit_cost: Decimal.new("1.00")
          }
        ]
      })
  end

  defp write_off(ctx, quantity) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: ctx.lot.id,
            location_id: ctx.warehouse.id,
            box_id: ctx.box.id,
            quantity: Decimal.new(-quantity)
          }
        ]
      })
  end

  describe "in_stock?/1" do
    test "is false for a product nothing was ever received of", ctx do
      refute Catalog.in_stock?(ctx.product)
    end

    test "is true while any lot is on a shelf", ctx do
      receive_stock(ctx, 10)

      assert Catalog.in_stock?(ctx.product)
    end

    test "is false again once the balance is back to zero", ctx do
      receive_stock(ctx, 10)
      write_off(ctx, 10)

      refute Catalog.in_stock?(ctx.product)
    end
  end

  describe "deactivate_product/2" do
    test "is refused while the product is still on a shelf", ctx do
      receive_stock(ctx, 10)

      assert {:error, :in_stock} = Catalog.deactivate_product(ctx.product)
      assert Repo.reload(ctx.product).active
    end

    test "takes it out of the catalog once nothing is left", ctx do
      receive_stock(ctx, 10)
      write_off(ctx, 10)

      assert {:ok, updated} = Catalog.deactivate_product(ctx.product)
      refute updated.active
    end

    # The flag is not the point on its own — every picker asking for it is. A
    # deactivated product that still comes back from a search is the bug this
    # whole thing exists to prevent.
    test "removes it from the catalog listing and from search", ctx do
      assert Enum.any?(Catalog.list_products(), &(&1.id == ctx.product.id))
      assert Enum.any?(Catalog.list_products(search: "gaze"), &(&1.id == ctx.product.id))

      {:ok, _} = Catalog.deactivate_product(ctx.product)

      refute Enum.any?(Catalog.list_products(), &(&1.id == ctx.product.id))
      refute Enum.any?(Catalog.list_products(search: "gaze"), &(&1.id == ctx.product.id))
    end

    test "records who did it, as a change on the product", ctx do
      user = EstoqueOS.AccountsFixtures.user_fixture()

      {:ok, _} = Catalog.deactivate_product(ctx.product, user_id: user.id)

      assert [change] = Catalog.product_changes(ctx.product.id)
      assert change.field == "active"
      assert change.from_value == "true"
      assert change.to_value == "false"
      assert change.user_id == user.id
    end

    # The row is what owns the history, so it has to survive: a recall asks
    # about goods that left years ago, and a product that vanished cannot answer.
    test "leaves the row, its lots and its movements alone", ctx do
      receive_stock(ctx, 10)
      write_off(ctx, 10)

      {:ok, _} = Catalog.deactivate_product(ctx.product)

      assert Repo.reload(ctx.product)
      assert Repo.reload(ctx.lot)
      assert Catalog.get_product!(ctx.product.id).name == "Gaze estéril"
    end
  end

  describe "reactivate_product/2" do
    test "puts it back, and says so in the log", ctx do
      {:ok, _} = Catalog.deactivate_product(ctx.product)
      {:ok, updated} = Catalog.reactivate_product(ctx.product)

      assert updated.active
      assert Enum.any?(Catalog.list_products(), &(&1.id == ctx.product.id))

      assert [%ProductChange{field: "active", from_value: "false", to_value: "true"} | _] =
               Catalog.product_changes(ctx.product.id)
    end
  end
end
