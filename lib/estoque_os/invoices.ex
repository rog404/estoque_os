defmodule EstoqueOS.Invoices do
  @moduledoc """
  Importing supplier invoices and turning them into stock.

  The flow is deliberately in two steps. `import_document/2` parses and stores
  the invoice with whatever it could match on its own; `post_invoice/2` is what
  actually touches the ledger, and it refuses to run while any line is still
  unresolved. Between the two sits a human confirming products and pack sizes.
  """

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Lot
  alias EstoqueOS.Invoices.{Invoice, InvoiceEvent, InvoiceItem}
  alias EstoqueOS.Repo

  @importers [EstoqueOS.Invoices.Importers.NFe]

  @doc "The importers this installation knows about."
  def importers, do: @importers

  @doc """
  Parses a supplier document and stores it, matching what it can.

  Returns `{:error, :already_imported, invoice}` when the access key is already
  on file — re-uploading the same XML must never duplicate stock.
  """
  def import_document(document, opts \\ []) do
    with {:ok, importer} <- importer_for(document),
         {:ok, parsed} <- importer.parse(document) do
      case get_invoice_by_access_key(parsed.access_key) do
        nil -> store(parsed, opts)
        invoice -> {:error, :already_imported, invoice}
      end
    end
  end

  defp importer_for(document) do
    case Enum.find(@importers, & &1.supports?(document)) do
      nil -> {:error, :unsupported_document}
      importer -> {:ok, importer}
    end
  end

  defp store(parsed, opts) do
    Multi.new()
    |> Multi.run(:supplier, fn _repo, _changes -> Catalog.upsert_supplier(parsed.supplier) end)
    |> Multi.insert(:invoice, fn %{supplier: supplier} ->
      Invoice.changeset(%Invoice{}, %{
        access_key: parsed.access_key,
        number: parsed.number,
        series: parsed.series,
        issued_on: parsed.issued_on,
        total: parsed.total,
        raw_xml: parsed.raw_xml,
        status: "parsed",
        segment: opts[:segment] || "medical",
        supplier_id: supplier.id,
        imported_by_id: opts[:user_id],
        items: Enum.map(parsed.items, &line_attrs(&1, supplier.id))
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice}} -> {:ok, load_invoice(invoice)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Matching happens per line at import time so the human only sees what is
  # genuinely ambiguous.
  defp line_attrs(line, supplier_id) do
    {product_id, factor} =
      case Catalog.match(line, supplier_id) do
        {:matched, product, _reason} ->
          {product.id, confirmed_or_suggested_factor(product, line)}

        {:unmatched, _suggestions} ->
          # The product is still unknown, but the pack size we read off the
          # description is kept so the resolve screen can prefill it.
          {nil, line.suggested_conversion_factor}
      end

    %{
      item_number: line.item_number,
      supplier_product_code: line.supplier_product_code,
      gtin: line.gtin,
      description: line.description,
      ncm: line.ncm,
      anvisa_code: line.anvisa_code,
      commercial_unit: line.commercial_unit,
      commercial_quantity: line.commercial_quantity,
      commercial_unit_value: line.commercial_unit_value,
      total_value: line.total_value,
      additional_info: line.additional_info,
      lot_number: line.lot_number,
      manufactured_on: line.manufactured_on,
      expires_on: line.expires_on,
      lot_source: line.lot_source,
      product_id: product_id,
      conversion_factor: factor,
      unit_cost: unit_cost(line.commercial_unit_value, factor),
      needs_review: line.needs_review or is_nil(product_id) or is_nil(factor)
    }
  end

  # A factor the team already confirmed for this product wins over the pack
  # size we guessed from the description.
  defp confirmed_or_suggested_factor(product, line) do
    case Catalog.get_conversion(product.id, line.commercial_unit) do
      nil -> line.suggested_conversion_factor
      conversion -> conversion.factor
    end
  end

  @doc """
  The unit price: the commercial-unit value divided by how many stock units
  come in it. Public so a screen can preview it as the factor is typed,
  without a second copy of the division that decides what a mission's goods
  actually cost.
  """
  def unit_cost(_value, nil), do: nil
  def unit_cost(nil, _factor), do: nil

  def unit_cost(value, factor) do
    if Decimal.equal?(factor, 0), do: nil, else: Decimal.div(value, factor)
  end

  @doc """
  Attaches a CC-e (or other SEFAZ event) to the invoice it corrects.
  """
  def attach_event(document) do
    with {:ok, parsed} <- EstoqueOS.Invoices.Importers.NFe.parse_event(document) do
      case get_invoice_by_access_key(parsed.access_key) do
        nil ->
          {:error, :invoice_not_imported}

        invoice ->
          %InvoiceEvent{}
          |> InvoiceEvent.changeset(Map.put(parsed, :invoice_id, invoice.id))
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:invoice_id, :kind, :sequence]
          )
      end
    end
  end

  ## Reading

  def get_invoice_by_access_key(access_key), do: Repo.get_by(Invoice, access_key: access_key)

  def get_invoice!(id), do: Invoice |> Repo.get!(id) |> load_invoice()

  # Items come back in the order the NF-e lists them, always. Without the
  # `order_by` Postgres returns them however the plan produced them, and an
  # updated row moves — so confirming line 1 sent it to the bottom of the screen
  # and the operator lost their place in a forty-line invoice. It also has to
  # match the paper: somebody is reading the DANFE beside this.
  defp load_invoice(invoice) do
    items = from(i in InvoiceItem, order_by: [asc: i.item_number, asc: i.id], preload: :product)

    Repo.preload(invoice, [:supplier, :events, items: items], force: true)
  end

  def list_invoices(opts \\ []) do
    Invoice
    |> maybe_segment(opts[:segment])
    |> order_by([i], desc: i.issued_on, desc: i.id)
    |> limit(^(opts[:limit] || 50))
    |> preload([:supplier])
    |> Repo.all()
  end

  @doc """
  Whether a scope confined to one stock may open this invoice at all.

  Two ways in, because a delivery belongs to a stock in two different senses.
  The invoice *was imported for* a stock — that is the answer while its lines
  are still unresolved, and it is the one that was missing: a marketing user
  uploaded an XML, no line had a product yet, and the screen told them the
  document they had just created was not theirs.

  And a delivery *landed in* a stock, which is what makes a mixed one readable
  by both. A box of shirts on an otherwise surgical invoice is marketing's line
  to confirm, and hiding the whole document would send them back to typing it.
  """
  def visible?(%Invoice{} = invoice, nil), do: is_struct(invoice, Invoice)

  def visible?(%Invoice{segment: segment} = _invoice, segment), do: true

  def visible?(%Invoice{} = invoice, segment) do
    Repo.exists?(
      from i in InvoiceItem,
        join: p in Product,
        on: p.id == i.product_id,
        where: i.invoice_id == ^invoice.id and p.segment == ^segment
    )
  end

  # An invoice belongs to the segments its lines landed in. A mixed delivery is
  # therefore visible to both, and each of them sees their own lines on it —
  # which is the only reading that does not make somebody re-key a document the
  # system already parsed.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query

  defp maybe_segment(query, segment) do
    # Imported for this stock, or holding a line that landed in it. The first
    # half is what shows a marketing user the invoice they uploaded five
    # seconds ago; the second is what keeps a mixed delivery on both lists.
    of_segment =
      from i in InvoiceItem,
        join: p in Product,
        on: p.id == i.product_id,
        where: p.segment == ^segment,
        select: i.invoice_id

    where(query, [i], i.segment == ^segment or i.id in subquery(of_segment))
  end

  @doc """
  One invoice, with only the lines this scope may see.

  The document is the same document; what differs is which of its lines are
  about your stock.
  """
  def get_invoice!(id, segment) when is_binary(segment) do
    invoice = get_invoice!(id)

    %{invoice | items: Enum.filter(invoice.items, &item_of_segment?(&1, invoice, segment))}
  end

  def get_invoice!(id, nil), do: get_invoice!(id)

  # A resolved line belongs to its product's stock. An unresolved one belongs to
  # nobody yet, so it belongs to whoever the delivery was imported for — which
  # is what makes the marketing coordinator able to resolve the lines on the
  # invoice they just uploaded.
  defp item_of_segment?(%InvoiceItem{product: %Product{segment: segment}}, _invoice, segment),
    do: true

  defp item_of_segment?(%InvoiceItem{product: nil}, %Invoice{segment: segment}, segment), do: true
  defp item_of_segment?(_item, _invoice, _segment), do: false

  @doc "Lines a human still has to resolve before the invoice can be posted."
  def unresolved_items(%Invoice{} = invoice) do
    Enum.filter(invoice.items, &unresolved?/1)
  end

  defp unresolved?(item) do
    is_nil(item.product_id) or is_nil(item.conversion_factor) or is_nil(item.lot_number)
  end

  ## Resolving

  @doc """
  Applies a human decision to one line: which product it is, how many stock
  units the commercial unit holds, and the lot data when the invoice lacked it.

  Remembers the supplier's GTIN and code for the product so the next invoice
  matches on its own, and recomputes the unit cost.
  """
  def resolve_item(%InvoiceItem{} = item, attrs, opts \\ []) do
    attrs = normalize_resolution(item, attrs)

    Multi.new()
    |> Multi.update(:item, InvoiceItem.changeset(item, attrs))
    |> Multi.run(:identifiers, fn _repo, %{item: item} -> remember_identifiers(item) end)
    |> Multi.run(:conversion, fn _repo, %{item: item} -> remember_conversion(item, opts) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{item: item}} -> {:ok, item}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp normalize_resolution(item, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    factor = attrs["conversion_factor"] || item.conversion_factor
    factor = if is_binary(factor), do: to_decimal(factor), else: factor

    attrs
    |> Map.put("conversion_factor", factor)
    |> Map.put("unit_cost", unit_cost(item.commercial_unit_value, factor))
    |> then(fn attrs ->
      resolved? =
        (attrs["product_id"] || item.product_id) && factor &&
          (attrs["lot_number"] || item.lot_number)

      Map.put(attrs, "needs_review", !resolved?)
    end)
  end

  defp remember_identifiers(%InvoiceItem{product_id: nil}), do: {:ok, []}

  defp remember_identifiers(item) do
    invoice = Repo.get!(Invoice, item.invoice_id)

    identifiers =
      [
        item.gtin && %{kind: "gtin", value: item.gtin, product_id: item.product_id},
        item.supplier_product_code &&
          %{
            kind: "supplier_code",
            value: item.supplier_product_code,
            product_id: item.product_id,
            supplier_id: invoice.supplier_id
          }
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Catalog.remember_identifier/1)

    {:ok, identifiers}
  end

  defp remember_conversion(%InvoiceItem{product_id: nil}, _opts), do: {:ok, nil}
  defp remember_conversion(%InvoiceItem{conversion_factor: nil}, _opts), do: {:ok, nil}

  defp remember_conversion(item, opts) do
    case Catalog.confirm_conversion(%{
           product_id: item.product_id,
           from_unit: item.commercial_unit,
           factor: item.conversion_factor,
           confirmed_by_id: opts[:user_id]
         }) do
      {:ok, conversion} -> {:ok, conversion}
      {:error, changeset} -> {:error, changeset}
    end
  end

  ## Sanity check

  @doc """
  Unit costs that are wildly off this product's history, for the confirmation
  screen to block on.
  """
  def suspicious_items(%Invoice{} = invoice) do
    invoice.items
    |> Enum.map(fn item ->
      case item.product_id && Catalog.check_unit_cost(item.product_id, item.unit_cost) do
        {:suspicious, details} -> Map.put(details, :item, item)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## Posting

  @doc """
  Posts the invoice into the ledger as a `purchase_in` transaction.

  Creates the lots the invoice describes, converts commercial quantities into
  stock units and snapshots the derived unit cost on every entry. Refuses to
  run while any line is unresolved, and refuses to run twice.
  """
  def post_invoice(%Invoice{} = invoice, %{location_id: location_id} = opts) do
    invoice = load_invoice(invoice)

    cond do
      invoice.status == "posted" ->
        {:error, :already_posted}

      unresolved_items(invoice) != [] ->
        {:error, {:unresolved_items, unresolved_items(invoice)}}

      true ->
        do_post(invoice, location_id, opts)
    end
  end

  defp do_post(invoice, location_id, opts) do
    Multi.new()
    |> Multi.run(:lots, fn _repo, _changes -> ensure_lots(invoice) end)
    |> Multi.run(:transaction, fn _repo, %{lots: lots} ->
      Inventory.post_transaction(%{
        type: "purchase_in",
        occurred_at: DateTime.new!(invoice.issued_on, ~T[12:00:00]),
        destination_location_id: location_id,
        invoice_id: invoice.id,
        user_id: opts[:user_id],
        entries: Enum.map(invoice.items, &entry_attrs(&1, lots, location_id, opts))
      })
    end)
    |> Multi.update(:invoice, fn _changes ->
      Invoice.changeset(invoice, %{status: "posted", posted_at: DateTime.utc_now(:second)})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice, transaction: transaction}} ->
        {:ok, %{invoice: load_invoice(invoice), transaction: transaction}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp entry_attrs(item, lots, location_id, opts) do
    %{
      lot_id: Map.fetch!(lots, item.id).id,
      location_id: location_id,
      box_id: opts[:box_id],
      quantity: Decimal.mult(item.commercial_quantity, item.conversion_factor),
      unit_cost: item.unit_cost
    }
  end

  defp ensure_lots(invoice) do
    Enum.reduce_while(invoice.items, {:ok, %{}}, fn item, {:ok, acc} ->
      case ensure_lot(item) do
        {:ok, lot} -> {:cont, {:ok, Map.put(acc, item.id, lot)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_lot(item) do
    case Repo.get_by(Lot, product_id: item.product_id, lot_number: item.lot_number) do
      nil ->
        %Lot{}
        |> Lot.changeset(%{
          product_id: item.product_id,
          lot_number: item.lot_number,
          manufactured_on: item.manufactured_on,
          expires_on: item.expires_on,
          needs_review: is_nil(item.lot_number)
        })
        |> Repo.insert()

      lot ->
        # A lot we already know may gain the expiry date this invoice carries.
        lot
        |> Lot.changeset(%{
          manufactured_on: lot.manufactured_on || item.manufactured_on,
          expires_on: lot.expires_on || item.expires_on
        })
        |> Repo.update()
    end
  end
end
