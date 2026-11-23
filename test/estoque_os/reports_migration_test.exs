defmodule EstoqueOS.ReportsMigrationTest do
  @moduledoc """
  The initial migration import (`create_missing: true`): a from-zero load that
  creates the products, locations, boxes and lots the count names, and registers
  box-only rows as empty boxes. The recurring count (no flag) still refuses an
  unknown product.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Location}
  alias EstoqueOS.Reports

  @header ["Produto", "Lote", "Validade", "Caixa", "Local", "Quantidade"]

  defp sheet(rows) do
    alias Elixlsx.{Sheet, Workbook}
    s = %Sheet{name: "Estoque", rows: [@header | rows]}
    {:ok, {_name, bin}} = Elixlsx.write_to_memory(%Workbook{sheets: [s]}, "e.xlsx")
    bin
  end

  describe "import_stock/2 with create_missing (initial migration)" do
    test "creates products, location, box and lot, and posts the stock" do
      bin =
        sheet([
          ["Gaze estéril 7,5cm", "L2291", "30/09/2027", "CX01", "Missão Porto Velho - RO", 40],
          ["Avental cirúrgico EG", "MIGRACAO", "", "CX01", "Missão Porto Velho - RO", 20]
        ])

      assert {:ok, result} = Reports.import_stock(bin, user_id: actor_id(), create_missing: true)
      assert result.adjusted == 2

      location = Repo.get_by!(Location, name: "Missão Porto Velho - RO")
      assert location.kind == "mission_site"

      box = Repo.get_by!(Box, code: "CX01")
      assert box.location_id == location.id
      assert box.last_verified_at
      assert result.boxes_verified == 1

      gaze = Repo.get_by!(Product, name: "GAZE ESTÉRIL 7,5CM")

      assert Decimal.equal?(
               Inventory.balance(product_id: gaze.id, box_id: box.id),
               Decimal.new(40)
             )
    end

    test "a box-only row registers the box with nothing inside it" do
      bin =
        sheet([
          ["", "", "", "OR84", "Missão Porto Velho - RO", ""]
        ])

      assert {:ok, result} = Reports.import_stock(bin, user_id: actor_id(), create_missing: true)
      assert result.adjusted == 0
      assert result.boxes_verified == 1

      box = Repo.get_by!(Box, code: "OR84")
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(0))
    end

    test "the same name in another case is one product, not two" do
      bin =
        sheet([
          ["Soro fisiológico 500ml", "A1", "", "CX02", "Missão Porto Velho - RO", 5],
          ["SORO FISIOLÓGICO 500ML", "B2", "", "CX02", "Missão Porto Velho - RO", 3]
        ])

      assert {:ok, _} = Reports.import_stock(bin, user_id: actor_id(), create_missing: true)

      matches =
        Repo.all(
          from p in EstoqueOS.Catalog.Product,
            where: fragment("lower(?)", p.name) == "soro fisiológico 500ml"
        )

      assert length(matches) == 1
    end
  end

  describe "import_stock/2 without the flag (recurring count)" do
    test "an unknown product is still refused" do
      bin = sheet([["Produto inexistente", "", "", "CX09", "Missão X", 5]])

      assert {:error, [error]} = Reports.import_stock(bin, user_id: actor_id())
      assert error.message =~ "não está no catálogo"
    end
  end
end
