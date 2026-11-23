defmodule EstoqueOS.Outbound.Shipment do
  @moduledoc """
  One load, on the road.

  Sending a mission's supplies and receiving them back are one act in opposite
  directions; sending creates the shipment, receiving closes it. It records what
  the single "Trânsito" location cannot: which load, with whom, since when.

  The location still holds the balance: goods on a truck must be somewhere, and
  leaving them at the origin falsifies it ("estoque em trânsito", SPEC §3.5).

  `received_at` null means "still out there"; derived, not a status column, so
  there is one place to write "received".

  `arrived_at` only applies to a hired carrier: stock is in neither place
  between leaving and landing, so it stays in transit until somebody at the
  other end says it landed. Arrived is the load reaching the mission; received
  is the mission handing back what it did not use.
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
    field :arrived_at, :utc_datetime
    field :received_at, :utc_datetime
    field :notes, :string

    belongs_to :from_location, Location
    belongs_to :to_location, Location
    belongs_to :carrier, Carrier
    belongs_to :mission, Mission
    belongs_to :received_by, User
    belongs_to :sent_transaction, Transaction
    belongs_to :arrival_transaction, Transaction
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
  Stamps the arrival: the load reached the place it was going.

  Only a load with a carrier ever has one. The movement it points at is the one
  that took the goods out of transit and put them where they were addressed.
  """
  def arrival_changeset(shipment, attrs) do
    shipment
    |> cast(attrs, [:arrived_at, :arrival_transaction_id])
    |> validate_required([:arrived_at, :arrival_transaction_id])
    |> assoc_constraint(:arrival_transaction)
    |> check_constraint(:arrived_at, name: :shipments_arrival_needs_both_or_neither)
  end

  @doc """
  Closes the shipment: what went out has come back, and this is that movement.
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

  @doc """
  Whether this load is on the road right now: a carrier has it and nobody at
  the other end has said it landed.
  """
  def in_transit?(%__MODULE__{carrier_id: carrier_id, arrived_at: nil})
      when not is_nil(carrier_id),
      do: true

  def in_transit?(%__MODULE__{}), do: false

  defp put_default_shipped_on(changeset) do
    if get_field(changeset, :shipped_on) do
      changeset
    else
      put_change(changeset, :shipped_on, Date.utc_today())
    end
  end

  # Arriving before leaving is a typo; the transit report counts days against it.
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
