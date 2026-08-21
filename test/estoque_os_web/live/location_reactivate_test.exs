defmodule EstoqueOSWeb.LocationReactivateTest do
  @moduledoc """
  A place leaves the operation and comes back.

  The mission that ran last year runs again, and the name is unique — so the way
  back has to be the same row, not a second one typed in with the same name.
  Retiring one is still only allowed once nothing is standing there, and "there"
  now means the floor as well as the boxes.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations

  setup :register_and_log_in_operator

  setup do
    %{warehouse: location_fixture(%{name: "Estoque Principal", kind: "warehouse"})}
  end

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp stock_at(location, quantity, opts \\ []) do
    product = product_fixture(%{name: "Compressa de gaze"})
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  test "a retired location can be put back to work", %{conn: conn} do
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    {:ok, _} = Locations.deactivate_location(site)

    {:ok, view, html} = live(conn, ~p"/locations")

    # One list. The retired place keeps its row and says so on it.
    assert text(html) =~ "Missão Tefé"
    assert text(html) =~ "desativado"

    back =
      view
      |> element(~s{button[phx-click="reactivate"][phx-value-id="#{site.id}"]})
      |> render_click()

    assert text(back) =~ "voltou a ser usado"
    assert Locations.get_location!(site.id).active
    assert Enum.any?(Locations.list_locations(), &(&1.id == site.id))
  end

  # A row offers one way out, never both: a place that is working can be
  # retired, a retired one can come back.
  test "a working location is not offered the way back", %{conn: conn, warehouse: warehouse} do
    {:ok, _view, html} = live(conn, ~p"/locations")

    refute html =~ ~s{phx-value-id="#{warehouse.id}" phx-click="reactivate"}
    refute text(html) =~ "desativado"
  end

  test "the list narrows by name and by kind", %{conn: conn} do
    location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    {:ok, view, _html} = live(conn, ~p"/locations")

    by_name = view |> form("#location-search", %{"search" => "tefe"}) |> render_change()

    assert text(by_name) =~ "Missão Tefé"
    refute text(by_name) =~ "Estoque Principal"

    by_kind = view |> form("#location-search", %{"search" => "deposito"}) |> render_change()

    assert text(by_kind) =~ "Estoque Principal"
    refute text(by_kind) =~ "Missão Tefé"
  end

  test "a search that matches nothing says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/locations")

    empty = view |> form("#location-search", %{"search" => "zzzz"}) |> render_change()

    assert text(empty) =~ "Nenhum local corresponde"
    refute text(empty) =~ "Nenhum local cadastrado"
  end

  # The retired ones are history; the working list is what the screen is for.
  test "retired places sort below the working ones", %{conn: conn} do
    site = location_fixture(%{name: "Alfa", kind: "warehouse"})
    {:ok, _} = Locations.deactivate_location(site)

    {:ok, _view, html} = live(conn, ~p"/locations")

    page = text(html)
    working = page |> String.split("Estoque Principal") |> hd() |> String.length()
    retired = page |> String.split("Alfa") |> hd() |> String.length()

    assert working < retired
  end

  test "stock lying loose on the floor blocks the retirement", %{conn: conn, warehouse: warehouse} do
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    stock_at(site, 30)

    {:ok, view, _html} = live(conn, ~p"/locations")

    refused = render_hook(view, "deactivate", %{"id" => "#{site.id}"})

    assert text(refused) =~ "ainda tem estoque"
    assert Locations.get_location!(site.id).active
    assert Locations.get_location!(warehouse.id).active
  end

  test "a box at the location blocks it too", %{conn: conn} do
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    box_fixture(%{code: "TF01", location_id: site.id})

    {:ok, view, _html} = live(conn, ~p"/locations")

    refused = render_hook(view, "deactivate", %{"id" => "#{site.id}"})

    assert text(refused) =~ "ainda tem estoque"
    assert Locations.get_location!(site.id).active
  end

  test "an empty location retires", %{conn: conn} do
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    {:ok, view, _html} = live(conn, ~p"/locations")

    render_hook(view, "deactivate", %{"id" => "#{site.id}"})

    refute Locations.get_location!(site.id).active
  end

  # The context is what says no, so an event that never passed through the
  # screen gets the same answer.
  test "the context refuses a location that still holds stock" do
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    stock_at(site, 5)

    assert {:error, :not_empty} = Locations.deactivate_location(site)
  end
end
