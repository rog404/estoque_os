defmodule EstoqueOS.Catalog.Supplier do
  @moduledoc """
  A supplier the ONG buys from, identified by its CNPJ.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "suppliers" do
    field :cnpj, :string
    field :legal_name, :string
    field :trade_name, :string
    field :email, :string
    field :phone, :string
    field :city, :string
    field :state, :string
    field :notes, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(supplier, attrs) do
    supplier
    |> cast(attrs, [
      :cnpj,
      :legal_name,
      :trade_name,
      :email,
      :phone,
      :city,
      :state,
      :notes,
      :active
    ])
    |> update_change(:cnpj, &digits_only/1)
    |> validate_required([:cnpj, :legal_name])
    |> validate_format(:cnpj, ~r/^\d{14}$/)
    |> validate_length(:state, is: 2)
    |> unique_constraint(:cnpj)
    |> check_constraint(:cnpj, name: :suppliers_cnpj_must_have_14_digits)
  end

  defp digits_only(nil), do: nil
  defp digits_only(value), do: String.replace(value, ~r/\D/, "")
end
