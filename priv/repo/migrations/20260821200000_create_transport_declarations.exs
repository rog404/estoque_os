defmodule EstoqueOS.Repo.Migrations.CreateTransportDeclarations do
  use Ecto.Migration

  # The paper that travels with the load. Its own table rather than columns on
  # `shipments`: most loads never need one — the volunteer's car does not — and
  # eight nullable columns on the record every screen reads would make the
  # exception look like part of the shipment.
  #
  # The recipient is written here rather than looked up from the location: the
  # hospital's registration is what was declared *on that day*, and a location
  # renamed or corrected later must not rewrite a document already signed.
  def change do
    create table(:transport_declarations) do
      add :shipment_id, references(:shipments, on_delete: :restrict), null: false

      add :recipient_name, :string, null: false
      add :recipient_document, :string
      add :recipient_address, :string
      add :recipient_postal_code, :string

      add :scheduling_code, :string
      add :invoice_number, :string
      add :reference, :string
      add :issued_on, :date, null: false

      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # One per load. Reprinting fills the same paper in again rather than
    # producing a second declaration for the same goods.
    create unique_index(:transport_declarations, [:shipment_id])
  end
end
