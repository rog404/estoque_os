defmodule EstoqueOS.Invoices.Invoice do
  @moduledoc """
  An imported NF-e. The 44-digit access key is the natural idempotency key:
  importing the same XML twice must not duplicate stock.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Catalog.Supplier
  alias EstoqueOS.Invoices.{InvoiceEvent, InvoiceItem}

  @statuses ~w(parsed matched posted cancelled)

  @doc "Known invoice statuses."
  def statuses, do: @statuses

  schema "invoices" do
    field :access_key, :string
    field :number, :string
    field :series, :string
    field :issued_on, :date
    field :total, :decimal
    field :raw_xml, :string
    field :status, :string, default: "parsed"
    field :posted_at, :utc_datetime

    belongs_to :supplier, Supplier
    belongs_to :imported_by, User

    has_many :items, InvoiceItem
    has_many :events, InvoiceEvent

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :access_key,
      :number,
      :series,
      :issued_on,
      :total,
      :raw_xml,
      :status,
      :posted_at,
      :supplier_id,
      :imported_by_id
    ])
    |> validate_required([:access_key, :number, :issued_on, :raw_xml, :status, :supplier_id])
    |> validate_format(:access_key, ~r/^\d{44}$/)
    |> validate_inclusion(:status, @statuses)
    |> cast_assoc(:items, with: &InvoiceItem.changeset/2)
    |> assoc_constraint(:supplier)
    |> assoc_constraint(:imported_by)
    |> unique_constraint(:access_key)
    |> check_constraint(:access_key, name: :invoices_access_key_must_have_44_digits)
    |> check_constraint(:status, name: :invoices_status_must_be_known)
  end
end
