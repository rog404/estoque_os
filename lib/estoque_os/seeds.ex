defmodule EstoqueOS.Seeds do
  @moduledoc """
  Loads the starting data: the locations the operation uses, the OSI standard
  supply table as the product catalog, and the mission kits.

  The source spreadsheets are real and messy — missing NCMs, a unit column
  reading "OK", a sector typed both "CRASHBOX" and "CRASHBIX", four repeated
  descriptions, and one description with a spreadsheet range reference pasted
  into the middle of a word. We normalize what is safe to normalize (whitespace,
  casing, NCM digits, that range reference) and keep the rest as written: a seed
  is not the place to quietly rewrite what the coordinator typed. The line
  between the two is whether a person typed it — `CRASHBIX` is a typo and stays,
  `+A1:P376` is the tool and goes.

  Suppliers are deliberately not seeded. The standard table lists them by name
  only, and a supplier without its CNPJ is not identifiable — they are created
  with the real CNPJ the first time one of their invoices is imported.
  """

  import Ecto.Query

  alias EstoqueOS.Accounts
  alias EstoqueOS.Catalog
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Kits
  alias EstoqueOS.Kits.Kit
  alias EstoqueOS.Repo
  alias EstoqueOS.Samples

  @locations [
    %{name: "Escritório SP", kind: "warehouse"},
    %{name: "Estoque Principal", kind: "warehouse"},
    %{name: "Trânsito", kind: "transit"}
  ]

  @catalog_sheet "Tabela padrão - Suprimentos méd"

  @doc """
  Runs every seed. Safe to run twice: existing rows are left alone.
  """
  def run(opts \\ []) do
    %{
      locations: seed_locations(),
      products: seed_catalog(opts[:catalog_sheet] || Samples.catalog_sheet()),
      kits: seed_kits(opts[:kits_sheet] || Samples.kits_sheet())
    }
  end

  # The four accounts a from-zero test deployment needs, one per role that has a
  # screen worth seeing. All on a throwaway domain, all sharing one password,
  # and all cleared of the forced first-login reset — a demo account that
  # demands a new password before it shows anything is a demo that does not
  # open. Real accounts the admin creates still carry the reset.
  #
  # The password is read from BOOTSTRAP_PASSWORD, never committed: this repo is
  # public, so a real credential cannot live in the source. The fallback is an
  # obvious placeholder for local dev that a deployment overrides through the
  # environment.
  @bootstrap_password_placeholder "trocar-em-producao"
  @bootstrap_users [
    %{email: "admin@estoque.local", role: "admin"},
    %{email: "estoque@estoque.local", role: "manager"},
    %{email: "logistica@estoque.local", role: "logistics"},
    %{email: "marketing@estoque.local", role: "marketing"}
  ]

  # The patient kit as the mission describes it by hand (the WhatsApp list). The
  # other kits are created by name only — their contents are raised later, in
  # the app. Lines carry a description and a quantity; the product is matched
  # when a catalog exists and stays unresolved until then.
  @patient_kit_items [
    {"Fixador de acesso venoso", 1},
    {"Gaze Ray Tec", 1},
    {"Luva estéril 6,0", 1},
    {"Luva estéril 6,5", 1},
    {"Luva estéril 7,0", 1},
    {"Luva estéril 7,5", 1},
    {"Luva não estéril P", 1},
    {"Luva não estéril M", 1},
    {"Luva não estéril G", 1},
    {"Gaze com fio radiopaco", 30},
    {"Gaze comum", 30},
    {"Lâmina de bisturi 15", 1},
    {"Lâmina de bisturi 11", 1},
    {"Micropore", 1},
    {"Gelco 22", 1},
    {"Gelco 24", 1},
    {"Extensor", 1},
    {"Bureta", 1},
    {"Equipo macro", 1},
    {"Equipo micro", 1},
    {"Fita crepe", 1},
    {"Seringa", 1},
    {"Álcool", 1},
    {"Clorexidina alcoólica", 1},
    {"Clorexidina aquosa", 1},
    {"PVPI (antisséptico amarelo)", 1},
    {"Soro", 1},
    {"Compressa", 30},
    {"Máscara", 1},
    {"Fixador de punção", 1},
    {"Agulha", 1},
    {"Transferidor de soro", 1},
    {"Tubo extensor para aspiração", 1}
  ]

  @mission_kits [
    {"Kit Paciente", @patient_kit_items},
    {"Kit Anestesia", []},
    {"Kit Enfermagem", []},
    {"Kit Pré e Pós", []},
    {"Kit Recuperação", []}
  ]

  @doc """
  The starting data for a from-zero deployment that will receive its real stock
  by import: the locations, the mission kits, and the role accounts. No catalog
  and no stock — the catalog is built by importing the adjusted control, and the
  stock rides in on the same import.

  Safe to run twice: existing rows and accounts are left alone.
  """
  def bootstrap do
    %{
      locations: seed_locations(),
      kits: seed_mission_kits(),
      users: seed_users()
    }
  end

  @doc "Creates the role accounts a test deployment logs in with."
  def seed_users do
    Enum.map(@bootstrap_users, fn %{email: email, role: role} ->
      case Accounts.get_user_by_email(email) do
        nil -> create_bootstrap_user(email, role)
        user -> user
      end
    end)
  end

  defp create_bootstrap_user(email, role) do
    {:ok, {user, _password}} =
      Accounts.create_user_with_temporary_password(email, role, password: bootstrap_password())

    user
    |> Ecto.Changeset.change(
      must_reset_password: false,
      confirmed_at: user.confirmed_at || DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  @doc "The password every bootstrap account shares, from the environment."
  def bootstrap_password do
    case System.get_env("BOOTSTRAP_PASSWORD") do
      nil -> @bootstrap_password_placeholder
      "" -> @bootstrap_password_placeholder
      password -> password
    end
  end

  @doc "Creates the five mission kits; only the patient kit carries items."
  def seed_mission_kits do
    Enum.map(@mission_kits, fn {name, items} ->
      case Repo.one(from k in Kit, where: fragment("lower(?)", k.name) == ^String.downcase(name)) do
        nil ->
          item_attrs =
            Enum.map(items, fn {description, quantity} ->
              %{description: description, quantity: Decimal.new(quantity)}
            end)

          {:ok, kit} = Kits.create_kit(%{name: name, items: item_attrs})
          kit

        kit ->
          kit
      end
    end)
  end

  def seed_locations do
    Enum.map(@locations, fn attrs ->
      case Repo.get_by(Location, name: attrs.name) do
        nil -> %Location{} |> Location.changeset(attrs) |> Repo.insert!()
        location -> location
      end
    end)
  end

  @doc """
  Seeds the product catalog from the OSI standard supply table.

  The QUANTIDADE column is what a four-table mission is expected to carry, so
  it seeds the per-product minimum stock rather than any balance.
  """
  def seed_catalog(path) do
    path
    |> rows(@catalog_sheet)
    |> Enum.drop(1)
    |> Enum.map(&catalog_attrs/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&String.downcase(&1.name))
    |> Enum.map(&upsert_product/1)
  end

  defp catalog_attrs([description | rest]) do
    case description |> text() |> strip_spreadsheet_artifact() do
      nil ->
        nil

      name ->
        [quantity, _note, ncm, unit, classification, sector] = pad(rest, 6)
        {ncm, ncm_note} = ncm(ncm)

        %{
          name: name,
          ncm: ncm,
          # Stock is always counted in individual units; the spreadsheet's
          # column is the *purchase* packaging, kept as a note.
          stock_unit: "UN",
          min_stock_override: positive_decimal(quantity),
          classification: text(classification),
          sector: text(sector),
          controlled: controlled?(classification, name),
          notes: notes([purchase_unit_note(text(unit)), ncm_note])
        }
    end
  end

  defp catalog_attrs(_row), do: nil

  # Three rows carry an NCM that is not an NCM: two 11-digit codes and one the
  # spreadsheet turned into a date. We refuse to store them as a classification
  # code, but we keep what was typed so a human can fix it.
  defp ncm(value) do
    case value do
      nil ->
        {nil, nil}

      %Date{} = date ->
        {nil, "NCM na tabela padrão: #{Calendar.strftime(date, "%d/%m/%Y")} (inválido)"}

      %NaiveDateTime{} = datetime ->
        {nil, "NCM na tabela padrão: #{Calendar.strftime(datetime, "%d/%m/%Y")} (inválido)"}

      value ->
        raw = text(value)
        digits = raw |> to_string() |> String.replace(~r/\D/, "")

        if String.length(digits) == 8 do
          {digits, nil}
        else
          {nil, "NCM na tabela padrão: #{raw} (inválido)"}
        end
    end
  end

  defp notes(parts) do
    case parts |> Enum.reject(&is_nil/1) |> Enum.join(". ") do
      "" -> nil
      notes -> notes
    end
  end

  defp purchase_unit_note(nil), do: nil
  defp purchase_unit_note("OK"), do: nil
  defp purchase_unit_note(unit), do: "Unidade de compra na tabela padrão: #{unit}"

  # Portaria 344 items ride in this stock too; the standard table only marks
  # them as medication, so this is a starting point a human refines later.
  defp controlled?(classification, _name) do
    case text(classification) do
      nil -> false
      value -> String.downcase(value) =~ "medicamento"
    end
  end

  defp upsert_product(attrs) do
    case Repo.one(
           from p in Product,
             where: fragment("lower(?)", p.name) == ^String.downcase(attrs.name)
         ) do
      nil ->
        {:ok, product} = Catalog.create_product(attrs)
        product

      product ->
        product
    end
  end

  @doc """
  Seeds the mission kits, one per sheet.

  Kit sheets name items in free text that rarely matches the catalog exactly,
  so lines keep their description and get a product only when the name matches
  outright. The rest stay visible as unresolved components.
  """
  def seed_kits(path) do
    path
    |> sheet_names()
    |> Enum.map(&seed_kit(path, &1))
  end

  defp seed_kit(path, sheet_name) do
    rows = rows(path, sheet_name)
    title = rows |> Enum.at(1, []) |> Enum.at(1) |> text() || sheet_name

    items =
      rows
      |> Enum.drop(2)
      |> Enum.map(&kit_item_attrs/1)
      |> Enum.reject(&is_nil/1)

    case Repo.one(from k in Kit, where: fragment("lower(?)", k.name) == ^String.downcase(title)) do
      nil ->
        # Through the context, not `Repo.insert!/1`. A kit is a product —
        # assembling one converts components into a lot of the kit's own
        # product, and `Kits.create_kit/1` is what creates the pair. Inserting
        # the kit on its own seeded five kits that could never be assembled,
        # and the failure surfaced two contexts away, as a nil `kit.product`
        # inside the conversion.
        {:ok, kit} = Kits.create_kit(%{name: title, items: items})
        kit

      kit ->
        kit
    end
  end

  defp kit_item_attrs(row) do
    [_blank, description, quantity | _rest] = pad(row, 3)

    with name when not is_nil(name) <- text(description),
         %Decimal{} = quantity <- positive_decimal(quantity) do
      %{description: name, quantity: quantity, product_id: matching_product_id(name)}
    else
      _ -> nil
    end
  end

  defp matching_product_id(name) do
    case Repo.one(
           from p in Product,
             where: fragment("lower(?)", p.name) == ^String.downcase(name),
             select: p.id
         ) do
      nil -> nil
      id -> id
    end
  end

  ## Spreadsheet plumbing

  defp rows(path, sheet_name) do
    {:ok, package} = XlsxReader.open(path)
    {:ok, rows} = XlsxReader.sheet(package, sheet_name, number_type: Decimal, blank_value: nil)
    rows
  end

  defp sheet_names(path) do
    {:ok, package} = XlsxReader.open(path)
    XlsxReader.sheet_names(package)
  end

  defp pad(list, size) do
    list ++ List.duplicate(nil, max(size - length(list), 0))
  end

  @doc """
  Removes a spreadsheet range reference pasted into the middle of a word.

  Row 11 of the standard table reads `SOLUÇÃ+A1:P376O INJETÁVEL`: somebody had
  the range `A1:P376` on the clipboard and dropped it inside "SOLUÇÃO", which
  is why the catalog carried a product nobody could search for. Row 219 spells
  the same family correctly, so the intended text is not in doubt.

  This is not the module rewriting what the coordinator typed — nobody typed
  `+A1:P376`. It is a mechanical artefact of the tool, in the same class as the
  double spaces already normalized above it, and taking it out restores what
  was written rather than editing it.

  Narrow on purpose: it wants letters on both sides of the colon, so a
  concentration like `1:200,000` — which several real anaesthetics carry — is
  left alone.

      iex> strip_spreadsheet_artifact("SOLUÇÃ+A1:P376O INJETÁVEL")
      "SOLUÇÃO INJETÁVEL"

      iex> strip_spreadsheet_artifact("BUPIVACAÍNA 0,5% AMPOLA 20ML 1:200,000")
      "BUPIVACAÍNA 0,5% AMPOLA 20ML 1:200,000"

      iex> strip_spreadsheet_artifact(nil)
      nil
  """
  def strip_spreadsheet_artifact(nil), do: nil

  def strip_spreadsheet_artifact(name) when is_binary(name) do
    name
    |> String.replace(~r/\+?\$?[A-Za-z]{1,3}\$?\d{1,7}:\$?[A-Za-z]{1,3}\$?\d{1,7}/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp text(nil), do: nil
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp text(value) do
    case value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp positive_decimal(nil), do: nil
  defp positive_decimal(%Decimal{} = value), do: if(Decimal.positive?(value), do: value)

  defp positive_decimal(value) when is_number(value),
    do: positive_decimal(Decimal.new("#{value}"))

  defp positive_decimal(value) do
    case value |> to_string() |> String.trim() |> Decimal.parse() do
      {decimal, _rest} -> positive_decimal(decimal)
      :error -> nil
    end
  end
end
