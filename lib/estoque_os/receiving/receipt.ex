defmodule EstoqueOS.Receiving.Receipt do
  @moduledoc """
  One conference round of an invoice against what physically arrived.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Invoices.Invoice
  alias EstoqueOS.Receiving.ReceiptLine

  @statuses ~w(draft completed cancelled)

  @doc "Known receipt statuses."
  def statuses, do: @statuses

  schema "receipts" do
    field :round, :integer, default: 1
    field :status, :string, default: "draft"
    field :completed_at, :utc_datetime
    field :notes, :string

    belongs_to :invoice, Invoice
    belongs_to :location, Location
    belongs_to :counted_by, User

    has_many :lines, ReceiptLine

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :round,
      :status,
      :completed_at,
      :notes,
      :invoice_id,
      :location_id,
      :counted_by_id
    ])
    |> validate_required([:round, :status, :invoice_id, :location_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:round, greater_than: 0)
    |> cast_assoc(:lines, with: &ReceiptLine.changeset/2)
    |> assoc_constraint(:invoice)
    |> assoc_constraint(:location)
    |> assoc_constraint(:counted_by)
    |> unique_constraint([:invoice_id, :round])
    |> check_constraint(:status, name: :receipts_status_must_be_known)
  end
end
