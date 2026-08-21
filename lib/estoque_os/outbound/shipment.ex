defmodule EstoqueOS.Outbound.Shipment do
  @moduledoc """
  One load, on the road.

  Sending a mission's supplies out and receiving them back are the same act in
  opposite directions, and this is the thing both of them are about: sending
  creates it, receiving closes it. Before it existed the two screens had nothing
  between them — the ledger could say stock was in transit and not with whom,
  since when, expected where, or which load, because "Trânsito" is one location
  and two shipments travelling at once land in the same bucket.

  The location still holds the balance. Every figure in this system is a quantity
  somewhere, and goods on a truck have to be somewhere: leaving them at the
  origin makes the origin's balance a lie, and "estoque em trânsito" is a number
  the accountant asks for by name (SPEC §3.5). The place answers *how much*; the
  shipment answers everything the place cannot know.

  `received_at` being null is what "still out there" means. Derived rather than a
  status column, for the same reason balances are derived: two places to write
  "received" is one place for them to disagree.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Catalog.Carrier
  alias EstoqueOS.Inventory.{Location, Transaction}
  alias EstoqueOS.Missions.Mission

  schema "shipments" do
    field :waybill, :string
    field :shipped_on, :date
    field :expected_arrival, :date
    field :received_at, :utc_datetime
    field :notes, :string

    belongs_to :from_location, Location
    belongs_to :to_location, Location
    belongs_to :carrier, Carrier
    belongs_to :mission, Mission
    belongs_to :received_by, User
    belongs_to :sent_transaction, Transaction
    belongs_to :received_transaction, Transaction

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(shipment, attrs) do
    shipment
    |> cast(attrs, [
      :waybill,
      :shipped_on,
      :expected_arrival,
      :notes,
      :from_location_id,
      :to_location_id,
      :carrier_id,
      :mission_id,
      :sent_transaction_id
    ])
    |> put_default_shipped_on()
    |> validate_required([:from_location_id, :to_location_id, :shipped_on, :sent_transaction_id])
    |> validate_arrival_after_departure()
    |> assoc_constraint(:from_location)
    |> assoc_constraint(:to_location)
    |> assoc_constraint(:carrier)
    |> assoc_constraint(:sent_transaction)
    |> check_constraint(:to_location_id, name: :shipments_must_travel_between_two_places)
  end

  @doc """
  Closes the shipment: it arrived, and this is the movement that took it in.
  """
  def receipt_changeset(shipment, attrs) do
    shipment
    |> cast(attrs, [:received_at, :received_by_id, :received_transaction_id])
    |> validate_required([:received_at, :received_transaction_id])
    |> assoc_constraint(:received_transaction)
    |> check_constraint(:received_at, name: :shipments_received_needs_both_or_neither)
  end

  @doc "Whether this load is still out there."
  def open?(%__MODULE__{received_at: nil}), do: true
  def open?(%__MODULE__{}), do: false

  defp put_default_shipped_on(changeset) do
    if get_field(changeset, :shipped_on) do
      changeset
    else
      put_change(changeset, :shipped_on, Date.utc_today())
    end
  end

  # A load that arrives before it leaves is a typo, and the date is what the
  # transit report sorts and counts days against.
  defp validate_arrival_after_departure(changeset) do
    shipped = get_field(changeset, :shipped_on)
    expected = get_field(changeset, :expected_arrival)

    if shipped && expected && Date.before?(expected, shipped) do
      add_error(changeset, :expected_arrival, "cannot be before the load left")
    else
      changeset
    end
  end
end
