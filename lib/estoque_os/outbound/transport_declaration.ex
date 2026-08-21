defmodule EstoqueOS.Outbound.TransportDeclaration do
  @moduledoc """
  The declaração de conteúdo that travels with a load.

  A carrier asks for a paper that says what is inside, who is sending it, who
  receives it and that none of it is dangerous. The ONG typed it in Word for
  every trip, copying the item list out of this system by hand — which is the
  work this replaces.

  The recipient is written down here rather than read from the location at print
  time. What was declared is what was declared: a hospital renamed next month,
  or a registration corrected after a typo, must not rewrite a document somebody
  already signed.
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

    # What the carrier's paperwork calls the trip, and the invoice that covers
    # the goods. Both optional: a donation travelling to a mission has neither,
    # and a blank line on the printed page is the honest way to say so.
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

  # Typed with or without the dots, and the paper always prints them.
  defp normalize_document(nil), do: nil

  defp normalize_document(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  @doc """
  A CNPJ as the paper prints it, and whatever was typed when it is not one.

  Fourteen digits is a CNPJ; anything else is left alone rather than padded into
  a number that does not exist — a foreign consignee or a hospital that gave a
  CPF are both real, and both would be corrupted by forcing the mask.
  """
  def format_document(nil), do: nil

  def format_document(<<a::binary-2, b::binary-3, c::binary-3, d::binary-4, e::binary-2>>) do
    "#{a}.#{b}.#{c}/#{d}-#{e}"
  end

  def format_document(value), do: value
end
