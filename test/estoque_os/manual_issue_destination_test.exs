defmodule EstoqueOS.ManualIssueDestinationTest do
  @moduledoc """
  The destination of a manual issue is a queryable field, so "which items were
  donated" is answered by a query, not by reading notes.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound, Reports}

  alias EstoqueOS.Inventory.Locations

  defp stocked_product(quantity) do
    product = product_fixture()
    lot = lot_fixture(%{product_id: product.id})
    location = Locations.default_location() || location_fixture()

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [%{lot_id: lot.id, location_id: location.id, quantity: quantity}]
      })

    {product, location}
  end

  test "records where an issue went, and the ledger can be asked" do
    {donated, location} = stocked_product(10)
    {to_pacu, _} = stocked_product(10)

    {:ok, _} =
      Outbound.issue(donated.id, 4, %{
        location_id: location.id,
        user_id: actor_id(),
        destination: "donation",
        recipient_tax_id: "12.345.678/0001-95"
      })

    {:ok, _} =
      Outbound.issue(to_pacu.id, 2, %{
        location_id: location.id,
        user_id: actor_id(),
        destination: "pacu"
      })

    today = Date.utc_today()
    from = Date.add(today, -1)

    donations = Reports.transaction_log(from, today, destination: "donation")

    assert length(donations) == 1
    assert hd(donations).transaction.destination == "donation"

    # Kept as digits so two entries for the same institution match.
    assert hd(donations).transaction.recipient_tax_id == "12345678000195"

    assert Reports.transaction_log(from, today, destination: "pacu") |> length() == 1
    assert Reports.transaction_log(from, today) |> length() >= 2
  end

  test "a destination outside the list is refused" do
    {product, location} = stocked_product(5)

    assert {:error, changeset} =
             Outbound.issue(product.id, 1, %{
               location_id: location.id,
               user_id: actor_id(),
               destination: "wherever"
             })

    assert "is invalid" in errors_on(changeset).destination
  end

  test "an issue with no destination is refused" do
    {product, location} = stocked_product(5)

    assert {:error, :missing_destination} =
             Outbound.issue(product.id, 1, %{location_id: location.id, user_id: actor_id()})

    assert Decimal.equal?(EstoqueOS.Inventory.balance(location_id: location.id), Decimal.new(5))
  end
end
