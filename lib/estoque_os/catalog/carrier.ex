defmodule EstoqueOS.Catalog.Carrier do
  @moduledoc """
  Whoever carries a load between two places.

  A party like a supplier, as a record rather than free text so one carrier is
  not three spellings (SPEC §3.13).

  The CNPJ is optional: a volunteer with a van is not a company.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "carriers" do
    field :legal_name, :string
    field :trade_name, :string
    field :cnpj, :string
    field :email, :string
    field :phone, :string
    field :notes, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(carrier, attrs) do
    carrier
    |> cast(attrs, [:legal_name, :trade_name, :cnpj, :email, :phone, :notes, :active])
    |> update_change(:legal_name, &String.trim/1)
    |> update_change(:cnpj, &normalize_cnpj/1)
    |> validate_required([:legal_name])
    |> validate_length(:cnpj, is: 14)
    |> unique_constraint(:legal_name, name: :carriers_lower_legal_name_index)
    |> unique_constraint(:cnpj)
  end

  # Digits only: typed with dots and slashes it would never match itself.
  defp normalize_cnpj(nil), do: nil

  defp normalize_cnpj(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  @doc "The name to show: the trade name if there is one, the legal name otherwise."
  def name(%__MODULE__{trade_name: trade}) when is_binary(trade) and trade != "", do: trade
  def name(%__MODULE__{legal_name: legal}), do: legal
end
