defmodule EstoqueOS.DemoDataTest do
  @moduledoc """
  The demo scenario is what a person is shown first, and it is built by code
  that no screen exercises. It broke twice while being written — once because
  the seeded kits had no backing product and could not be assembled, once
  because three products were chosen to be short before two missions had spent
  them — and both failures were silent: the scenario loaded and simply did not
  contain what it claimed to.

  So the claims are asserted here rather than read off the console.

  `async: false` and one slow test rather than several: building the scenario
  takes most of a second, and it is one indivisible thing.
  """

  use EstoqueOS.DataCase, async: false

  import Ecto.Query

  alias EstoqueOS.Accounts
  alias EstoqueOS.DemoData
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Box
  alias EstoqueOS.Inventory.StockSnapshot
  alias EstoqueOS.Invoices
  alias EstoqueOS.Kits
  alias EstoqueOS.Repo
  alias EstoqueOS.Seeds

  setup do
    Seeds.run()
    {:ok, summary} = DemoData.run()
    %{summary: summary}
  end

  test "refuses to run twice, because running it again would double every balance" do
    assert {:error, :already_loaded} = DemoData.run()
  end

  describe "the account" do
    # One, and only one. Creating the rest is the administrator's first job on a
    # fresh install and a flow worth walking rather than seeding around.
    test "just the administrator, named for the role and not for a person",
         %{summary: summary} do
      assert summary.accounts == ["admin@exemplo.org"]
      assert Accounts.get_user_by_email("admin@exemplo.org").role == "admin"

      assert Accounts.list_users() |> length() == 1
    end

    # A demo account that demands a new password before it will show anything
    # is not a demo account. Accounts the administrator then creates *do* demand
    # one, which is the right default and is tested where it belongs.
    test "logs in with the published password and lands on the app, not on a reset",
         %{summary: summary} do
      [email] = summary.accounts

      assert Accounts.get_user_by_email_and_password(email, summary.password)
      refute Accounts.get_user_by_email(email).must_reset_password
    end
  end

  describe "the invoices" do
    test "one posted into stock and one still waiting", %{summary: summary} do
      assert summary.invoices.posted.status == "posted"
      assert summary.invoices.pending.status in ~w(parsed matched)
      refute summary.invoices.pending.posted_at
    end

    test "the posted one moved goods, at a cost that came from the document",
         %{summary: summary} do
      invoice = Invoices.get_invoice!(summary.invoices.posted.id)

      entries =
        Repo.all(
          from e in Inventory.TransactionEntry,
            join: t in assoc(e, :transaction),
            where: t.invoice_id == ^invoice.id,
            select: e
        )

      assert length(entries) == length(invoice.items)
      assert Enum.all?(entries, &(Decimal.compare(&1.quantity, 0) == :gt))

      # Never a symbolic cent, and never nil for a purchase: the whole point of
      # posting an invoice rather than typing a quantity is the unit cost.
      for entry <- entries do
        assert entry.unit_cost, "an invoice entry posted without a unit cost"
        assert Decimal.compare(entry.unit_cost, 0) == :gt
      end
    end

    test "the correction letter is attached to the invoice it corrects", %{summary: summary} do
      invoice = Invoices.get_invoice!(summary.invoices.posted.id)

      assert Enum.any?(invoice.events, &(&1.kind == "cce"))
    end
  end

  describe "the kits" do
    test "one is assembled and in stock as a product of its own", %{summary: summary} do
      assert {:ok, %{quantity: quantity}} = summary.assembled
      assert Decimal.compare(quantity, 0) == :gt

      kit = Kits.get_kit!(summary.kit.id)

      assert kit.product, "a kit without a product cannot be written off"
      assert Decimal.equal?(Kits.assembled_count(kit), quantity)
    end

    test "its recipe resolves completely — otherwise it could not be assembled",
         %{summary: summary} do
      kit = Kits.get_kit!(summary.kit.id)

      assert Kits.unresolved_items(kit) == []
    end

    # Both states at once, which is the whole reason the order in `build/0`
    # matters: a kit in the box, and the refusal waiting for whoever tries to
    # build the next one.
    test "one component has expired since, so assembling another is refused",
         %{summary: summary} do
      kit = Kits.get_kit!(summary.kit.id)
      warehouse = summary.warehouse

      availability = Kits.availability(kit, warehouse.id)

      assert [line] = availability.expired_components
      assert line.item.description == summary.expired_component

      assert {:error, {:expired_components, _}} =
               Kits.assemble(kit, 1, %{
                 location_id: warehouse.id,
                 box_id: EstoqueOS.Repo.get_by!(Box, code: "PR01").id,
                 user_id: Accounts.get_user_by_email("admin@exemplo.org").id
               })
    end

    # The four other kits are left as the spreadsheets wrote them. That state is
    # what the kit screen exists to work through, so the demo has to contain it.
    test "the other kits still show unresolved lines", %{summary: summary} do
      others =
        Kits.list_kits()
        |> Enum.reject(&(&1.id == summary.kit.id))
        |> Enum.map(&Kits.get_kit!(&1.id))

      assert others != []
      assert Enum.all?(others, &(Kits.unresolved_items(&1) != []))
    end
  end

  describe "the missions" do
    test "two are closed and one is under way", %{summary: summary} do
      today = Date.utc_today()

      for mission <- summary.closed_missions do
        assert Date.compare(mission.ends_on, today) == :lt
      end

      assert Date.compare(summary.open_mission.ends_on, today) != :lt
    end

    test "the open mission has goods sitting at its site", %{summary: summary} do
      at_site =
        Repo.aggregate(
          from(s in StockSnapshot,
            where: s.location_id == ^summary.open_mission.location_id and s.quantity > 0
          ),
          :count
        )

      assert at_site > 0
    end

    test "the closed missions left nothing behind at their sites", %{summary: summary} do
      for mission <- summary.closed_missions do
        left =
          Repo.aggregate(
            from(s in StockSnapshot,
              where: s.location_id == ^mission.location_id and s.quantity > 0
            ),
            :count
          )

        assert left == 0, "#{mission.name} still has stock at its site"
      end
    end
  end

  describe "the state the screens need" do
    test "boxes counted on both sides of the 30-day line, and some never counted" do
      cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

      fresh = Repo.aggregate(from(b in Box, where: b.last_verified_at > ^cutoff), :count)
      stale = Repo.aggregate(from(b in Box, where: b.last_verified_at < ^cutoff), :count)
      never = Repo.aggregate(from(b in Box, where: is_nil(b.last_verified_at)), :count)

      assert fresh > 0
      assert stale > 0
      assert never > 0
    end

    test "a shortage list short enough to act on", %{summary: summary} do
      assert summary.short_products == 3
    end

    test "stock that has already expired, and stock about to" do
      today = Date.utc_today()

      expired = positions_expiring_before(today)
      soon = positions_expiring_between(today, Date.add(today, 90))

      assert expired > 0
      assert soon > 0
    end
  end

  describe "the ledger" do
    # The invariant the whole design rests on. A scenario built by hand is
    # exactly where a snapshot and its entries can drift apart.
    test "every snapshot equals the sum of the entries behind it" do
      snapshots =
        Repo.all(
          from s in StockSnapshot,
            select: %{
              lot_id: s.lot_id,
              box_id: s.box_id,
              location_id: s.location_id,
              quantity: s.quantity
            }
        )

      assert snapshots != []

      for snapshot <- snapshots do
        derived =
          Inventory.balance(
            lot_id: snapshot.lot_id,
            box_id: snapshot.box_id,
            location_id: snapshot.location_id
          )

        assert Decimal.equal?(derived, snapshot.quantity),
               "snapshot #{inspect(snapshot)} disagrees with the ledger (#{derived})"
      end
    end

    test "no balance anywhere is negative" do
      negative =
        Repo.aggregate(from(s in StockSnapshot, where: s.quantity < 0), :count)

      assert negative == 0
    end
  end

  # The free-tier database this is demonstrated on stops at ten thousand rows.
  # A scenario that grows past it fails at deploy time, on someone else's
  # afternoon. Counted across every table the scenario writes to, with room to
  # spare rather than to the last row.
  test "the whole scenario fits in a free-tier database" do
    tables = [
      EstoqueOS.Accounts.User,
      EstoqueOS.Catalog.Product,
      EstoqueOS.Catalog.ProductIdentifier,
      EstoqueOS.Inventory.Box,
      EstoqueOS.Inventory.Location,
      EstoqueOS.Inventory.Lot,
      EstoqueOS.Inventory.StockSnapshot,
      EstoqueOS.Inventory.Transaction,
      EstoqueOS.Inventory.TransactionEntry,
      EstoqueOS.Invoices.Invoice,
      EstoqueOS.Invoices.InvoiceItem,
      EstoqueOS.Kits.Kit,
      EstoqueOS.Kits.KitItem,
      EstoqueOS.Missions.Mission
    ]

    total = Enum.sum(Enum.map(tables, &Repo.aggregate(&1, :count)))

    assert total < 5_000, "the scenario reaches #{total} rows, and the free tier stops at 10_000"
  end

  defp positions_expiring_before(date) do
    Repo.aggregate(
      from(s in StockSnapshot,
        join: l in assoc(s, :lot),
        where: s.quantity != 0 and l.expires_on < ^date
      ),
      :count
    )
  end

  defp positions_expiring_between(from_date, to_date) do
    Repo.aggregate(
      from(s in StockSnapshot,
        join: l in assoc(s, :lot),
        where: s.quantity != 0 and l.expires_on >= ^from_date and l.expires_on <= ^to_date
      ),
      :count
    )
  end
end
