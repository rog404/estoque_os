defmodule EstoqueOSWeb.ViewerWriteGuardTest do
  @moduledoc """
  Roles were enforced on the route and nowhere else.

  Screens that report to everyone still carry buttons that write — a box is moved
  from the box screen, a kit is packed from the kit screen — so blocking the route
  was never an option and the events went unguarded. A viewer could move a box
  between locations, pack a kit into the ledger, deactivate the warehouse, and
  mark a box as counted without opening it. That last one is the worst of them:
  `last_verified_at` is what separates a presumed balance from a verified one, and
  a false stamp is worse than no stamp.

  Two kinds of test here. The behavioural ones send the events and demand refusal.
  The structural one fails when somebody adds a `handle_event` and does not say
  whether a viewer may send it, which is how the hole appeared the first time.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}

  alias EstoqueOS.Inventory.Locations

  describe "a viewer" do
    setup :register_and_log_in_user

    setup do
      warehouse = location_fixture(%{name: "Estoque Principal"})
      %{warehouse: warehouse, box: box_fixture(%{code: "VG01", location_id: warehouse.id})}
    end

    test "cannot move a box out of its location", %{conn: conn, box: box} do
      elsewhere = location_fixture(%{name: "Missão Tefé"})
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      assert render_hook(view, "move", %{"location_id" => "#{elsewhere.id}"}) =~ "permissão"
      assert Locations.get_box!(box.id).location_id == box.location_id
    end

    test "cannot stamp a box as counted", %{conn: conn, box: box} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      assert render_hook(view, "verify", %{}) =~ "permissão"

      # A false verification is worse than none: it is the difference between a
      # presumed balance and one somebody actually opened the box to count.
      assert is_nil(Locations.get_box!(box.id).last_verified_at)
    end

    test "cannot create a box", %{conn: conn, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      assert render_hook(view, "create", %{"code" => "XX99", "location_id" => "#{warehouse.id}"}) =~
               "permissão"

      refute Enum.any?(Locations.list_boxes(warehouse.id), &(&1.code == "XX99"))
    end

    test "cannot create or deactivate a location", %{conn: conn, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/locations")

      assert render_hook(view, "create", %{"name" => "Inventado", "kind" => "warehouse"}) =~
               "permissão"

      assert render_hook(view, "deactivate", %{"id" => "#{warehouse.id}"}) =~ "permissão"

      refute Enum.any?(Locations.list_locations(), &(&1.name == "Inventado"))
      assert Locations.get_location!(warehouse.id).active
    end

    test "cannot pack a kit into the ledger", %{conn: conn, warehouse: warehouse, box: box} do
      gown = product_fixture(%{name: "Avental EG"})

      {:ok, kit} =
        Kits.create_kit(%{
          name: "Kit Paciente",
          items: [%{description: "Avental EG", quantity: Decimal.new(2), product_id: gown.id}]
        })

      lot = lot_fixture(%{product_id: gown.id, expires_on: ~D[2028-01-31]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: EstoqueOS.AccountsFixtures.user_fixture().id,
          entries: [%{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(10)}]
        })

      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      assert render_hook(view, "assemble", %{
               "quantity" => "2",
               "location_id" => "#{warehouse.id}",
               "box_id" => "#{box.id}"
             }) =~ "permissão"

      kit = Kits.get_kit!(kit.id)

      assert Decimal.equal?(
               Inventory.balance(box_id: box.id, product_id: kit.product.id),
               Decimal.new(0)
             )
    end

    test "still reads and filters what reports to everyone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stock")

      # The guard must not take the reporting away from the people it is for.
      refute render_hook(view, "filter", %{"query" => "avental"}) =~ "permissão"
      refute render_hook(view, "sort", %{"key" => "name"}) =~ "permissão"

      {:ok, issues, _html} = live(conn, ~p"/issues")
      refute render_hook(issues, "filter", %{"destination" => "donation"}) =~ "permissão"
    end

    test "is not shown the controls it would be refused", %{conn: conn, box: box} do
      {:ok, _view, boxes} = live(conn, ~p"/boxes")
      {:ok, _view, one_box} = live(conn, ~p"/boxes/#{box.id}")
      {:ok, _view, locations} = live(conn, ~p"/locations")

      # A button that always answers "sem permissão" teaches people to ignore
      # the interface. The guard and the markup read the same `@writable?`.
      refute boxes =~ ~s(id="new-box")
      refute one_box =~ ~s(id="move-form")
      refute one_box =~ ~s(phx-click="verify")
      refute locations =~ ~s(id="new-location")
      refute locations =~ ~s(phx-click="edit")
    end

    test "still changes its own email", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      refute render_hook(view, "validate_email", %{"user" => %{"email" => "x@example.com"}}) =~
               "permissão"
    end
  end

  describe "an operator" do
    setup :register_and_log_in_operator

    test "moves a box as before", %{conn: conn} do
      warehouse = location_fixture(%{name: "Estoque Principal"})
      elsewhere = location_fixture(%{name: "Missão Tefé"})
      box = box_fixture(%{code: "VG02", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
      refute render_hook(view, "move", %{"location_id" => "#{elsewhere.id}"}) =~ "permissão"

      assert Locations.get_box!(box.id).location_id == elsewhere.id
    end
  end

  describe "every screen a viewer can reach" do
    # Each entry is the events on that screen a viewer must NOT be able to send.
    # Adding a `handle_event` without classifying it fails this test, which is the
    # point: the hole was one forgotten handler, not a wrong decision.
    @write_events %{
      # The spreadsheet left this screen for `/reports/data`; what remains here
      # reports, and `search` is a read like the rest of them.
      "stock_live/index" => ~w(),
      # `search` narrows a list and is not here: it is declared as a viewer
      # event on the screen itself.
      "box_live/index" => ~w(create move),
      "box_live/show" => ~w(move verify rebox stow confirm_new_box cancel_new_box),
      "location_live/index" =>
        ~w(create edit cancel_rename rename deactivate reactivate set_default),
      "kit_live/index" => ~w(create),
      "kit_live/show" =>
        ~w(assemble add_item update_item remove_item confirm_new_box cancel_new_box),
      "invoice_live/show" => ~w(resolve post start_receipt),
      # `draft` writes nothing — it only remembers what has been typed so that
      # recording one line stops blanking the others. It is still refused to a
      # viewer: somebody who may not record a count has no count to keep.
      "receipt_live/show" => ~w(count complete draft confirm_new_box cancel_new_box count_again),
      # Closing an alert is a planning decision — the same gate the minimum and
      # the kit recipe sit behind — so a viewer may not send it. The `Alerts`
      # context refuses it a second time, because the bell in the layout is a
      # component and its events never pass this hook.
      "home_live/index" => ~w(acknowledge_count),
      "issue_live/list" => ~w(),
      "audit_report_live/index" => ~w(),
      "user_live/settings" => ~w(),
      # Planning, not stock: a minimum is argued with the ONG team, and only
      # admin and manager may set it. Refused to a viewer like any other write.
      "product_live/show" => ~w(set_minimum stow),
      "mission_live/index" => ~w(create),
      "mission_live/show" => ~w(reschedule)
    }

    # The list above was hand-written, which meant a new screen was simply absent
    # from it and checked by nothing — exactly the shape of the original hole,
    # one level up. The screens now come from the router.
    test "every screen in the signed-in session is classified here" do
      router = File.read!("lib/estoque_os_web/router.ex")

      [_, block] =
        Regex.run(~r/live_session :signed_in,(.*?)\n    end\n/s, router)

      routed =
        Regex.scan(~r/live "[^"]+", (\w+)\.(\w+),/, block)
        |> Enum.map(fn [_, namespace, module] ->
          "#{macro_to_path(namespace)}/#{macro_to_path(module)}"
        end)
        |> Enum.uniq()

      with_events =
        Enum.filter(routed, fn screen ->
          path = "lib/estoque_os_web/live/#{screen}.ex"
          File.exists?(path) and File.read!(path) =~ ~r/def handle_event\("/
        end)

      assert Enum.sort(with_events -- Map.keys(@write_events)) == [],
             """
             A screen a viewer can reach has events nobody classified:
             #{inspect(with_events -- Map.keys(@write_events))}

             Add it to @write_events with the events that must be refused.
             """
    end

    defp macro_to_path(name) do
      name
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
    end

    test "classifies every event as readable by a viewer or refused to one" do
      for {screen, expected_writes} <- @write_events do
        path = "lib/estoque_os_web/live/#{screen}.ex"
        source = File.read!(path)

        events =
          Regex.scan(~r/def handle_event\("([^"]+)"/, source)
          |> Enum.map(&List.last/1)
          |> Enum.uniq()

        # `\s` and not a literal space: once the list is long enough the
        # formatter puts `do:` on its own line, and a declaration this test
        # cannot see reads here as a screen that declared nothing at all.
        declared =
          case Regex.run(~r/def viewer_events,\s*do:\s*~w\(([^)]*)\)/s, source) do
            [_, list] -> String.split(list, ~r/\s+/, trim: true)
            nil -> []
          end

        assert Enum.sort(events -- declared) == Enum.sort(expected_writes),
               """
               #{path} has events nobody classified.

               events:   #{inspect(Enum.sort(events))}
               declared: #{inspect(Enum.sort(declared))}
               expected to be refused to a viewer: #{inspect(Enum.sort(expected_writes))}

               Add the event to `viewer_events/0` if a viewer may send it, or to
               this test's map if it writes.
               """

        assert declared -- events == [],
               "#{path} declares viewer events that no longer exist: #{inspect(declared -- events)}"
      end
    end
  end
end
