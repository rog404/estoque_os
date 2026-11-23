defmodule EstoqueOS.Catalog do
  @moduledoc """
  Products, groups, identifiers, suppliers and unit conversions.

  Where an invoice line becomes one of our products: `match/1` tries GTIN,
  then the supplier's code, and only then guesses from the description. The
  order matters: supplier wording is the least reliable evidence.
  """

  import Ecto.Query
  import EstoqueOS.Coercion

  alias EstoqueOS.Catalog.{
    Carrier,
    Product,
    ProductChange,
    ProductGroup,
    ProductGroupSynonym,
    ProductIdentifier,
    Supplier,
    UnitConversion
  }

  alias EstoqueOS.Inventory.{Lot, StockSnapshot, TransactionEntry}
  alias EstoqueOS.Repo

  # A derived unit cost this far from the product's history is almost always
  # the classic total-vs-unit swap, not a real price change.
  @unit_cost_divergence_factor Decimal.new(10)

  @doc "The factor at which a unit cost is considered suspicious."
  def unit_cost_divergence_factor, do: @unit_cost_divergence_factor

  def get_supplier_by_cnpj(cnpj) when is_binary(cnpj) do
    Repo.get_by(Supplier, cnpj: String.replace(cnpj, ~r/\D/, ""))
  end

  @doc """
  Finds a supplier by CNPJ or creates it from the invoice data.

  An NF-e issued under a CPF (nota avulsa for a donation) has no CNPJ; that
  returns an error the import screen can phrase.
  """
  def upsert_supplier(attrs) do
    case field(attrs, :cnpj) do
      cnpj when is_binary(cnpj) and cnpj != "" ->
        case get_supplier_by_cnpj(cnpj) do
          nil -> %Supplier{} |> Supplier.changeset(attrs) |> Repo.insert()
          supplier -> {:ok, supplier}
        end

      _missing ->
        {:error, :supplier_missing_cnpj}
    end
  end

  def create_supplier(attrs), do: %Supplier{} |> Supplier.changeset(attrs) |> Repo.insert()

  def list_suppliers do
    Supplier |> order_by([s], asc: s.legal_name) |> Repo.all()
  end

  def get_product!(id), do: Repo.get!(Product, id)

  @doc """
  The product, or `:error` when there is no such id.

  For ids that arrived in a URL: a product deactivated in the meantime is a
  dead link, not a crash.
  """
  def fetch_product(id) do
    case Repo.get(Product, id) do
      nil -> :error
      product -> {:ok, product}
    end
  end

  def create_product(attrs), do: %Product{} |> Product.changeset(attrs) |> Repo.insert()

  @doc """
  A name reduced to what two people typing the same product would agree on.

  Accents, case, punctuation and spacing are dropped; words and measurements
  survive. Letters and digits are separated and a measurement is kept whole
  (`7,5cm` and `7.5 CM` give the same tokens; `3.0` and `4.0` do not share one).

      iex> normalize_for_match("Gaze Estéril  7,5cm")
      ["gaze", "esteril", "7.5", "cm"]

      iex> normalize_for_match("GAZE ESTERIL 7.5 CM")
      ["gaze", "esteril", "7.5", "cm"]

      iex> normalize_for_match("Tubo 3.0 MM")
      ["tubo", "3", "mm"]

      iex> normalize_for_match("FIO 5-0 VICRYL")
      ["fio", "5-0", "vicryl"]

      iex> normalize_for_match(nil)
      []

  """
  def normalize_for_match(nil), do: []

  def normalize_for_match(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    |> then(&Regex.scan(~r/[0-9]+(?:[.,:\/-][0-9]+)*|[a-z]+/u, &1))
    |> Enum.map(fn [token] -> normalize_number(token) end)
  end

  # `3.0` and `3` are the same measurement written twice; `5-0` and `1:200,000`
  # are not decimals and are left exactly as they are.
  defp normalize_number(token) do
    case Regex.run(~r/^([0-9]+)[.,]([0-9]+)$/, token) do
      [_all, whole, fraction] ->
        case String.trim_trailing(fraction, "0") do
          "" -> whole
          trimmed -> whole <> "." <> trimmed
        end

      nil ->
        token
    end
  end

  @doc """
  The measurements in a name: every token carrying a digit.

  In surgical supply the numbers *are* the product: a 3.0 mm tube is for an
  infant, a 7.0 mm for an adult, and merging them is a clinical problem.

      iex> measurements("TUBO ENDOTRAQUEAL PRE-FORMADO 3.0 MM - COM BALÃO")
      ["3"]

      iex> measurements("Compressa de gaze")
      []

  """
  def measurements(name) do
    name
    |> normalize_for_match()
    |> Enum.filter(&String.match?(&1, ~r/[0-9]/))
    |> Enum.sort()
  end

  @doc """
  Catalog entries close enough to `name` that creating it would probably be a
  duplicate, most alike first.

  The unique index on `lower(name)` only catches exact repeats, not near-misses
  like "GAZE ESTERIL 7,5CM" vs "Gaze estéril 7,5 cm". Scored on shared words,
  not substrings, because word order varies.
  """
  def similar_products(name, opts \\ []) do
    case normalize_for_match(name) do
      [] ->
        []

      words ->
        threshold = opts[:threshold] || 0.6
        wanted = MapSet.new(words)
        wanted_measurements = measurements(name)

        candidates(words, opts)
        |> Enum.reject(&different_product?(wanted_measurements, &1.name))
        |> Enum.map(&{&1, similarity(wanted, MapSet.new(normalize_for_match(&1.name)))})
        |> Enum.filter(fn {_product, score} -> score >= threshold end)
        |> Enum.sort_by(fn {_product, score} -> score end, :desc)
        |> Enum.map(fn {product, score} -> %{product: product, score: score} end)
        |> Enum.take(opts[:limit] || 5)
    end
  end

  # Anything sharing a word worth sharing. Short tokens like "de" or "5" match
  # half the catalog, so the net is cast with the longest ones.
  defp candidates(words, opts) do
    significant =
      words
      |> Enum.filter(&(String.length(&1) >= 4))
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.take(3)
      |> case do
        [] -> Enum.take(words, 1)
        found -> found
      end

    # Word matches are OR'd together, then AND'd with `active`; `or_where`
    # would OR against the active filter and return deactivated products.
    matches_a_word =
      Enum.reduce(significant, dynamic(false), fn word, acc ->
        dynamic([p], ^acc or ilike(p.name, ^"%#{word}%"))
      end)

    Product
    |> where([p], p.active)
    |> where(^matches_a_word)
    |> maybe_exclude(opts[:except_id])
    |> limit(200)
    |> Repo.all()
  end

  defp maybe_exclude(query, nil), do: query
  defp maybe_exclude(query, id), do: where(query, [p], p.id != ^id)

  # Names whose measurements disagree are two products however many words they
  # share (word overlap alone scores 3.0 mm vs 7.0 mm tubes at 0.89). Only when
  # *both* carry measurements: nothing to compare is not a difference.
  defp different_product?([], _other_name), do: false

  defp different_product?(wanted_measurements, other_name) do
    case measurements(other_name) do
      [] -> false
      found -> found != wanted_measurements
    end
  end

  # Overlap over the larger set: "gaze" alone must not read as a perfect match
  # for "gaze estéril 7,5cm".
  defp similarity(wanted, found) do
    shared = MapSet.intersection(wanted, found) |> MapSet.size()
    largest = max(MapSet.size(wanted), MapSet.size(found))

    if largest == 0, do: 0.0, else: shared / largest
  end

  @doc """
  Creates a product, refusing when the catalog already has something close.

  Returns `{:error, {:similar, matches}}` so the caller can show what it found
  and let a human say "none of these". Pass `confirmed: true` to go ahead anyway
  — sometimes two products really are that alike.
  """
  def create_product_checked(attrs, opts \\ []) do
    name = attrs[:name] || attrs["name"]

    case opts[:confirmed] && true do
      true ->
        create_product(attrs)

      _ ->
        case similar_products(name) do
          [] -> create_product(attrs)
          matches -> {:error, {:similar, matches}}
        end
    end
  end

  @doc """
  A catalog name proposed from what the supplier wrote on the invoice.

  Suppliers append shipment data (code, lot, quantity, dates) to the
  description, often cut off mid-word:

      BUPIVACAINA S/V 0.5% 20ML GEN-HYPOFARMA (Fornecedor: 4219, Lote: 25071596, Qtde: 2 ,Data

  That tail is stripped (the importer parses lot and dates from the same text).
  A suggestion only: the operator edits it, as no rule survives every supplier.
  """
  def suggested_product_name(description) when is_binary(description) do
    description
    |> strip_shipment_tail()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_trailing(",")
    |> String.trim_trailing("-")
    |> String.trim()
    |> case do
      "" -> String.trim(description)
      name -> name
    end
  end

  def suggested_product_name(nil), do: nil

  # The tail starts at the parenthesis introducing shipment data, closed or not
  # (truncated descriptions lose the closing bracket).
  @shipment_keys ~w(Fornecedor Lote Qtde Qtd Data Val Fab Venc)

  defp strip_shipment_tail(description) do
    positions = Enum.map(:binary.matches(description, "("), fn {at, _len} -> at end)

    positions
    |> Enum.find(&shipment_group?(description, &1, positions))
    |> case do
      nil -> description
      at -> binary_part(description, 0, at)
    end
  end

  # Inspect only the group this parenthesis opens, or "SUGAMADEX (200MG) ...
  # (Fornecedor: 47" would be cut at the dose.
  defp shipment_group?(description, at, positions) do
    next = Enum.find(positions, byte_size(description), &(&1 > at))

    description
    |> binary_part(at, next - at)
    |> then(fn group -> Enum.any?(@shipment_keys, &String.contains?(group, &1 <> ":")) end)
  end

  def update_product(%Product{} = product, attrs) do
    product |> Product.changeset(attrs) |> Repo.update()
  end

  def change_product(%Product{} = product, attrs \\ %{}), do: Product.changeset(product, attrs)

  @doc """
  Sets the minimum a mission is expected to carry, and records who did it.

  Update and change-log row commit together: alarms and packing depend on this
  number, so "who lowered it" must always have an answer.

  A blank clears it to unknown, not zero (zero means "content to carry none").
  """
  def set_min_stock(%Product{} = product, value, opts \\ []) do
    minimum = blank_to_nil(value)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:product, Product.changeset(product, %{min_stock_override: minimum}))
    |> Ecto.Multi.insert(:change, fn %{product: updated} ->
      ProductChange.changeset(%ProductChange{}, %{
        product_id: updated.id,
        user_id: opts[:user_id],
        field: "min_stock_override",
        from_value: decimal_to_string(product.min_stock_override),
        to_value: decimal_to_string(updated.min_stock_override)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{product: updated}} -> {:ok, updated}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Takes a product out of the catalog without taking it out of the history.

  Every picker filters on `active`, so the flag is the whole mechanism. Nothing
  is deleted: history keeps naming the product and its page opens by id (a
  recall asks about goods that left years ago).

  Refused while any of it is on a shelf. That is a fact about the ledger, so it
  is checked here and not in the changeset.
  """
  def deactivate_product(%Product{} = product, opts \\ []) do
    if in_stock?(product) do
      {:error, :in_stock}
    else
      set_active(product, false, opts)
    end
  end

  @doc """
  Puts a product back in the catalog.

  Not a second row: identifiers are unique and the original row holds the history.
  """
  def reactivate_product(%Product{} = product, opts \\ []) do
    set_active(product, true, opts)
  end

  @doc """
  Whether any lot of this product is still on a shelf.

  `!= 0` rather than `> 0`: a negative balance is a bug that must not leave the
  catalog with the product.
  """
  def in_stock?(%Product{} = product), do: in_stock?(product.id)

  def in_stock?(product_id) do
    Repo.exists?(
      from s in StockSnapshot,
        join: l in Lot,
        on: l.id == s.lot_id,
        where: l.product_id == ^product_id and s.quantity != 0
    )
  end

  # Update and log row commit together, as in `set_min_stock/3`.
  defp set_active(%Product{} = product, active, opts) do
    # Reload: a stale struct makes the changeset a no-op that still reports
    # success, and `from_value` in the log must match the database row.
    product = Repo.reload!(product)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:product, Product.changeset(product, %{active: active}))
    |> Ecto.Multi.insert(:change, fn %{product: updated} ->
      ProductChange.changeset(%ProductChange{}, %{
        product_id: updated.id,
        user_id: opts[:user_id],
        field: "active",
        from_value: to_string(product.active),
        to_value: to_string(updated.active)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{product: updated}} -> {:ok, updated}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "What the catalog was told about this product, newest first."
  def product_changes(product_id, opts \\ []) do
    ProductChange
    |> where([c], c.product_id == ^product_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^(opts[:limit] || 5))
    |> preload(:user)
    |> Repo.all()
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: to_string(value)

  def list_products(opts \\ []) do
    Product
    |> where([p], p.active == true)
    |> maybe_segment(opts[:segment])
    |> maybe_search(opts[:search])
    |> order_by([p], asc: p.name)
    |> limit(^(opts[:limit] || 50))
    |> Repo.all()
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    pattern = "%#{String.trim(search)}%"
    where(query, [p], ilike(p.name, ^pattern))
  end

  # Which stock the caller is looking at, passed down from the scope.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query
  defp maybe_segment(query, segment), do: where(query, [p], p.segment == ^segment)

  @doc """
  Finds products the way a person actually looks for them.

  Same order as the invoice importer: an exact GTIN or supplier code is an
  answer and stops there; only then group synonyms and name, the weakest evidence.

  Returns `%{product: product, matched: :gtin | :supplier_code | :synonym |
  :name}` so the screen can say *why* something matched.
  """
  def search_products(term, opts \\ []) do
    case String.trim(to_string(term)) do
      "" -> []
      term -> by_code(term, opts) || by_words(term, opts)
    end
  end

  @doc """
  The single product a scanned code identifies, or nil.

  A keyboard-wedge scanner types digits and presses Enter; this is what that
  Enter resolves to.
  """
  def find_by_code(code, opts \\ []) do
    case by_code(code, opts) do
      [%{product: product}] -> product
      _ -> nil
    end
  end

  defp by_code(term, opts) do
    query =
      ProductIdentifier
      |> where([i], i.value == ^term)
      |> maybe_supplier(opts[:supplier_id])
      |> join(:inner, [i], p in Product, on: p.id == i.product_id)
      |> where([_i, p], p.active)
      |> segment_scope(opts[:segment])
      |> select([i, p], %{product: p, matched: i.kind})

    case Repo.all(query) do
      [] -> nil
      rows -> Enum.map(rows, &%{&1 | matched: String.to_existing_atom(&1.matched)})
    end
  end

  # A supplier code is only meaningful for that supplier; a GTIN is global.
  defp maybe_supplier(query, nil), do: where(query, [i], i.kind == "gtin")

  defp maybe_supplier(query, supplier_id) do
    where(query, [i], i.kind == "gtin" or i.supplier_id == ^supplier_id)
  end

  defp by_words(term, opts) do
    pattern = "%#{term}%"
    limit = opts[:limit] || 10

    synonyms =
      ProductGroupSynonym
      |> where([s], ilike(s.name, ^pattern))
      |> join(:inner, [s], p in Product, on: p.product_group_id == s.product_group_id)
      |> where([_s, p], p.active)
      |> segment_scope(opts[:segment])
      |> select([_s, p], %{product: p, matched: :synonym})
      |> limit(^limit)
      |> Repo.all()

    named =
      Product
      |> where([p], p.active and ilike(p.name, ^pattern))
      |> segment_scope(opts[:segment])
      |> order_by([p], asc: p.name)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&%{product: &1, matched: :name})

    (synonyms ++ named)
    |> Enum.uniq_by(& &1.product.id)
    |> Enum.take(limit)
  end

  # The product is the last binding in all three search queries.
  defp segment_scope(query, nil), do: query
  defp segment_scope(query, ""), do: query
  defp segment_scope(query, segment), do: where(query, [..., p], p.segment == ^segment)

  @doc "Carriers still in use, by the name a person would look for."
  def list_carriers do
    Carrier
    |> where([c], c.active)
    |> order_by([c], asc: c.legal_name)
    |> Repo.all()
  end

  @doc """
  The carrier by that name, creating it the first time it is seen.

  Case-insensitive: "STRALOG" and "Stralog" must be one carrier for the transit
  report to mean anything.
  """
  def resolve_carrier(name) do
    case String.trim(to_string(name)) do
      "" ->
        {:ok, nil}

      name ->
        case Repo.one(
               from c in Carrier,
                 where: fragment("lower(?)", c.legal_name) == ^String.downcase(name)
             ) do
          nil -> %Carrier{} |> Carrier.changeset(%{legal_name: name}) |> Repo.insert()
          carrier -> {:ok, carrier}
        end
    end
  end

  def create_product_group(attrs) do
    %ProductGroup{} |> ProductGroup.changeset(attrs) |> Repo.insert()
  end

  def add_group_synonym(attrs) do
    %ProductGroupSynonym{} |> ProductGroupSynonym.changeset(attrs) |> Repo.insert()
  end

  def get_product_by_gtin(nil), do: nil

  def get_product_by_gtin(gtin) do
    ProductIdentifier
    |> where([i], i.kind == "gtin" and i.value == ^gtin)
    |> join(:inner, [i], p in Product, on: p.id == i.product_id)
    |> select([_i, p], p)
    |> Repo.one()
  end

  def get_product_by_supplier_code(nil, _code), do: nil
  def get_product_by_supplier_code(_supplier_id, nil), do: nil

  def get_product_by_supplier_code(supplier_id, code) do
    ProductIdentifier
    |> where(
      [i],
      i.kind == "supplier_code" and i.value == ^code and i.supplier_id == ^supplier_id
    )
    |> join(:inner, [i], p in Product, on: p.id == i.product_id)
    |> select([_i, p], p)
    |> Repo.one()
  end

  @doc """
  Records how a supplier names a product, ignoring duplicates.

  This is what makes the second import of the same item automatic.
  """
  def remember_identifier(attrs) do
    %ProductIdentifier{}
    |> ProductIdentifier.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:kind, :value, :supplier_id])
  end

  @doc """
  Matches a parsed invoice line against the catalog.

  Returns `{:matched, product, reason}` when we are sure — a GTIN or a code
  this very supplier used before — or `{:unmatched, suggestions}` with ranked
  candidates for a human to pick from.
  """
  def match(line, supplier_id \\ nil) do
    cond do
      product = get_product_by_gtin(line[:gtin]) ->
        {:matched, product, :gtin}

      product = get_product_by_supplier_code(supplier_id, line[:supplier_product_code]) ->
        {:matched, product, :supplier_code}

      true ->
        {:unmatched, suggest_products(line[:description], line[:ncm])}
    end
  end

  @doc """
  Ranks catalog products against a supplier description.

  Deliberately dumb and offline: shared words, with a bonus for the same NCM.
  Warehouse staff type "bagagem" when they mean "bandagem", so this is a
  shortlist for a human, never an automatic match.
  """
  def suggest_products(description, ncm \\ nil, opts \\ [])
  def suggest_products(nil, _ncm, _opts), do: []

  def suggest_products(description, ncm, opts) do
    limit = opts[:limit] || 5
    wanted = tokenize(description)

    if wanted == [] do
      []
    else
      Product
      |> where([p], p.active == true)
      |> Repo.all()
      |> Enum.map(&{&1, score(&1, wanted, ncm)})
      |> Enum.reject(fn {_product, score} -> score <= 0.0 end)
      |> Enum.sort_by(fn {_product, score} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {product, score} -> %{product: product, score: Float.round(score, 3)} end)
    end
  end

  defp score(product, wanted, ncm) do
    tokens = tokenize(product.name)
    shared = tokens |> MapSet.new() |> MapSet.intersection(MapSet.new(wanted)) |> MapSet.size()

    base =
      if tokens == [] do
        0.0
      else
        shared / Enum.max([length(wanted), length(tokens)])
      end

    if ncm && product.ncm == ncm, do: base + 0.15, else: base
  end

  # Numbers and units carry the dosage ("500MG"), so they are kept as tokens;
  # only noise words and punctuation go.
  defp tokenize(nil), do: []

  defp tokenize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    # Combining marks are removed, not spaced: "estéril" must not split.
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or &1 in ~w(com para sem est ger gen)))
  end

  def get_conversion(product_id, unit) when is_binary(unit) do
    Repo.get_by(UnitConversion, product_id: product_id, from_unit: String.upcase(unit))
  end

  def get_conversion(_product_id, nil), do: nil

  @doc """
  Stores the confirmed "1 CX = 250 UN" factor for a product and unit.
  """
  def confirm_conversion(attrs) do
    attrs = Map.put_new(attrs, :confirmed_at, DateTime.utc_now(:second))

    %UnitConversion{}
    |> UnitConversion.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:factor, :confirmed_by_id, :confirmed_at, :updated_at]},
      conflict_target: [:product_id, :from_unit],
      returning: true
    )
  end

  @doc """
  The unit cost this product entered stock at most recently, or nil.
  """
  def last_unit_cost(product_id) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id == ^product_id and not is_nil(e.unit_cost))
    |> order_by([e], desc: e.id)
    |> limit(1)
    |> select([e], e.unit_cost)
    |> Repo.one()
  end

  @doc """
  Compares a derived unit cost against the product's history.

  Returns `:ok`, `:no_history`, or `{:suspicious, %{previous:, factor:}}` —
  the caller blocks and asks a human, because the usual cause is a total
  booked as a unit price.
  """
  def check_unit_cost(product_id, unit_cost)

  def check_unit_cost(_product_id, nil), do: :ok

  def check_unit_cost(product_id, unit_cost) do
    case last_unit_cost(product_id) do
      nil ->
        :no_history

      previous ->
        cond do
          # A zero cost is a bonus line, and the ratio would divide by it.
          Decimal.equal?(unit_cost, 0) ->
            :ok

          Decimal.equal?(previous, 0) ->
            :no_history

          diverges?(unit_cost, previous) ->
            {:suspicious, %{previous: previous, factor: divergence(unit_cost, previous)}}

          true ->
            :ok
        end
    end
  end

  defp diverges?(unit_cost, previous) do
    Decimal.compare(divergence(unit_cost, previous), @unit_cost_divergence_factor) != :lt
  end

  defp divergence(unit_cost, previous) do
    ratio = Decimal.div(unit_cost, previous)

    if Decimal.compare(ratio, 1) == :lt do
      Decimal.div(previous, unit_cost)
    else
      ratio
    end
  end
end
