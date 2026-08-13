defmodule EstoqueOS.InventoryFixtures do
  @moduledoc """
  Fixtures for the `EstoqueOS.Inventory` context.
  """

  import Ecto.Query

  import EstoqueOS.AccountsFixtures
  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Inventory.{Box, Location, Lot}
  alias EstoqueOS.Repo

  @doc """
  Somebody to attribute a movement to.

  Every ledger transaction must name who made it, so a test that posts one has
  to have an actor. Reuses the first user in the sandbox rather than minting a
  new one per entry.
  """
  def actor_id do
    case Repo.one(from u in User, limit: 1) do
      %User{id: id} -> id
      nil -> user_fixture().id
    end
  end

  def location_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{name: "Local #{System.unique_integer([:positive])}", kind: "warehouse"})
    |> then(&Location.changeset(%Location{}, &1))
    |> Repo.insert!()
  end

  def box_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      code: "AN#{System.unique_integer([:positive])}",
      location_id: attrs[:location_id] || location_fixture().id
    })
    |> then(&Box.changeset(%Box{}, &1))
    |> Repo.insert!()
  end

  def lot_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      lot_number: "L#{System.unique_integer([:positive])}",
      product_id: attrs[:product_id] || product_fixture().id
    })
    |> then(&Lot.changeset(%Lot{}, &1))
    |> Repo.insert!()
  end
end
