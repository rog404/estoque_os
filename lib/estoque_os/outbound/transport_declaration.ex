defmodule EstoqueOS.Outbound.TransportDeclaration do
  @moduledoc """
  The declaração de conteúdo that travels with a load.

  The paper a carrier asks for: contents, sender, recipient, nothing dangerous.

  The recipient is stored here, not read from the location at print time, so a
  later rename or corrected registration cannot rewrite a document already signed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Outbound.Shipment

  schema "transport_declarations" do
    field :recipient_name, :string
    field :recipient_document, :string
    field :recipient_address, :string
    field :recipient_postal_code, :string

    # Both optional: a donation travelling to a mission has neither.
    field :scheduling_code, :string
    field :invoice_number, :string
    field :reference, :string
    field :issued_on, :date

    belongs_to :shipment, Shipment
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(declaration, attrs) do
    declaration
    |> cast(attrs, [
      :recipient_name,
      :recipient_document,
      :recipient_address,
      :recipient_postal_code,
      :scheduling_code,
      :invoice_number,
      :reference,
      :issued_on,
      :shipment_id,
      :user_id
    ])
    |> update_change(:recipient_document, &normalize_document/1)
    |> validate_required([:recipient_name, :issued_on, :shipment_id])
    |> assoc_constraint(:shipment)
    |> unique_constraint(:shipment_id)
  end

  # Stored as digits; `format_document/1` adds the mask.
  defp normalize_document(nil), do: nil

  defp normalize_document(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  @doc """
  A CNPJ as the paper prints it, and whatever was typed when it is not one.

  Only fourteen digits is a CNPJ; anything else (a CPF, a foreign consignee) is
  left alone rather than corrupted by forcing the mask.
  """
  def format_document(nil), do: nil

  def format_document(<<a::binary-2, b::binary-3, c::binary-3, d::binary-4, e::binary-2>>) do
    "#{a}.#{b}.#{c}/#{d}-#{e}"
  end

  def format_document(value), do: value
end
