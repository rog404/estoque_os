defmodule EstoqueOS.Inventory.Transaction do
  @moduledoc """
  One movement of stock, with its signed entries. This is the only way stock
  ever changes: there is no editable balance anywhere in the system.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Inventory.{Location, TransactionEntry}
  alias EstoqueOS.Invoices.Invoice

  @types ~w(purchase_in donation_in transfer load_out return_in kit_assembly
            kit_consumption manual_out adjustment inventory_import)

  @reason_codes ~w(expiry damage loss count_correction other)

  # Where a manual issue went. A closed list so the ledger can answer "what was
  # donated" or "what was thrown out", which free-text `notes` cannot.
  # `sale` is the marketing stock's exit: a `manual_out` whose `sale_unit_price`
  # is on its entries, not a transaction type of its own.
  @destinations ~w(pacu operating_room donation pre_and_post triage disposal sale)

  @types_requiring_both_locations ~w(transfer load_out)

  @doc "Known transaction types."
  def types, do: @types

  @doc "Reason codes an adjustment must pick from."
  def reason_codes, do: @reason_codes

  @doc "Where a manual issue can go."
  def destinations, do: @destinations

  schema "transactions" do
    field :type, :string
    field :occurred_at, :utc_datetime
    field :reason_code, :string
    field :destination, :string
    field :recipient_name, :string
    field :recipient_tax_id, :string
    field :notes, :string
    field :review_reason, :string
    # Closes the alert without erasing `review_reason`.
    field :review_acknowledged_at, :utc_datetime
    field :review_acknowledgement, :string

    belongs_to :source_location, Location
    belongs_to :destination_location, Location
    belongs_to :user, User
    belongs_to :review_acknowledged_by, User
    belongs_to :invoice, Invoice
    belongs_to :mission, EstoqueOS.Missions.Mission
    # The trip the goods *left*, for a load-out straight from one mission to the next.
    belongs_to :source_mission, EstoqueOS.Missions.Mission

    has_many :entries, TransactionEntry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :type,
      :occurred_at,
      :reason_code,
      :destination,
      :recipient_name,
      :recipient_tax_id,
      :notes,
      :review_reason,
      :source_location_id,
      :destination_location_id,
      :user_id,
      :invoice_id,
      :mission_id,
      :source_mission_id
    ])
    |> put_default_occurred_at()
    # `user_id` is required: an auditor asks who moved the stock.
    |> validate_required([:type, :occurred_at, :user_id])
    |> validate_inclusion(:type, @types)
    |> update_change(:recipient_tax_id, &normalize_tax_id/1)
    |> validate_inclusion(:destination, @destinations)
    |> validate_reason_code()
    |> validate_locations()
    |> cast_assoc(:entries, required: true, with: &TransactionEntry.changeset/2)
    |> assoc_constraint(:source_location)
    |> assoc_constraint(:destination_location)
    |> assoc_constraint(:user)
    |> assoc_constraint(:invoice)
    |> check_constraint(:type, name: :transactions_type_must_be_known)
    |> check_constraint(:destination, name: :transactions_destination_must_be_known)
    |> check_constraint(:reason_code, name: :transactions_adjustments_need_a_reason)
    |> check_constraint(:source_location_id,
      name: :transactions_transfers_need_both_locations
    )
  end

  # Digits only: typed with dots and slashes it would never match itself.
  defp normalize_tax_id(nil), do: nil

  defp normalize_tax_id(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  defp put_default_occurred_at(changeset) do
    if get_field(changeset, :occurred_at) do
      changeset
    else
      put_change(changeset, :occurred_at, DateTime.utc_now(:second))
    end
  end

  # An adjustment without a reason is exactly what makes a stock unauditable.
  defp validate_reason_code(changeset) do
    if get_field(changeset, :type) == "adjustment" do
      changeset
      |> validate_required([:reason_code])
      |> validate_inclusion(:reason_code, @reason_codes)
    else
      changeset
    end
  end

  defp validate_locations(changeset) do
    if get_field(changeset, :type) in @types_requiring_both_locations do
      validate_required(changeset, [:source_location_id, :destination_location_id])
    else
      changeset
    end
  end
end
