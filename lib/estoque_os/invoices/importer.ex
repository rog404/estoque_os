defmodule EstoqueOS.Invoices.Importer do
  @moduledoc """
  Contract for turning a supplier document into invoice data we can post.

  Brazil ships with `EstoqueOS.Invoices.Importers.NFe` (layout 4.00). Other
  countries add their own module implementing this behaviour; nothing outside
  the importers knows what an NF-e is.

  `parse/1` returns a plain map, never database structs — matching invoice
  lines to our catalog is the caller's job.
  """

  @type supplier :: %{
          required(:cnpj) => String.t(),
          required(:legal_name) => String.t(),
          optional(:trade_name) => String.t() | nil,
          optional(:city) => String.t() | nil,
          optional(:state) => String.t() | nil,
          optional(:email) => String.t() | nil,
          optional(:phone) => String.t() | nil
        }

  @type item :: %{
          item_number: pos_integer(),
          supplier_product_code: String.t() | nil,
          gtin: String.t() | nil,
          description: String.t(),
          ncm: String.t() | nil,
          anvisa_code: String.t() | nil,
          commercial_unit: String.t(),
          commercial_quantity: Decimal.t(),
          commercial_unit_value: Decimal.t(),
          total_value: Decimal.t() | nil,
          additional_info: String.t() | nil,
          lot_number: String.t() | nil,
          manufactured_on: Date.t() | nil,
          expires_on: Date.t() | nil,
          lot_source: String.t(),
          needs_review: boolean(),
          suggested_conversion_factor: Decimal.t() | nil
        }

  @type invoice :: %{
          access_key: String.t(),
          number: String.t(),
          series: String.t() | nil,
          issued_on: Date.t(),
          total: Decimal.t() | nil,
          supplier: supplier(),
          items: [item()],
          raw_xml: String.t()
        }

  @doc "True when this importer recognizes the document."
  @callback supports?(document :: String.t()) :: boolean()

  @doc "Parses a document into invoice data."
  @callback parse(document :: String.t()) :: {:ok, invoice()} | {:error, term()}
end
