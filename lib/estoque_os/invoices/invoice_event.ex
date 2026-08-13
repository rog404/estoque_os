defmodule EstoqueOS.Invoices.InvoiceEvent do
  @moduledoc """
  An SEFAZ event attached to an invoice — in the MVP, the CC-e (correction
  letter) is stored and shown, but never reprocessed field by field.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Invoices.Invoice

  @kinds ~w(cce cancellation other)

  @doc "Known event kinds."
  def kinds, do: @kinds

  schema "invoice_events" do
    field :kind, :string
    field :sequence, :integer
    field :occurred_at, :utc_datetime
    field :description, :string
    field :raw_xml, :string

    belongs_to :invoice, Invoice

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:kind, :sequence, :occurred_at, :description, :raw_xml, :invoice_id])
    |> validate_required([:kind, :raw_xml, :invoice_id])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:invoice)
    |> unique_constraint([:invoice_id, :kind, :sequence])
    |> check_constraint(:kind, name: :invoice_events_kind_must_be_known)
  end
end
