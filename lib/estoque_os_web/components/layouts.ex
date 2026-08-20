defmodule EstoqueOSWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EstoqueOSWeb, :html

  alias EstoqueOS.Accounts.Scope

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_path, :string, default: nil, doc: "path of the page being shown, to mark the nav"

  slot :inner_block, required: true

  def app(assigns) do
    # Derived from the scope the layout already has, rather than threaded through
    # twenty-six screens that would each have to remember to pass it.
    assigns =
      assigns
      |> assign(:section, active_section(assigns[:current_path]))
      |> assign(:sees_money?, EstoqueOSWeb.UserAuth.sees_money?(assigns[:current_scope]))

    ~H"""
    <div data-section={@section}>
      <header class="app-bar navbar gap-2 px-4 sm:px-6 lg:px-8">
        <div class="flex-1 min-w-0">
          <.link navigate={~p"/"} class="flex w-fit items-center gap-2.5">
            <.mark />
            <span class="min-w-0 leading-none">
              <span class="block text-base font-semibold truncate">{gettext("Estoque")}</span>
              <span class="block text-[0.6875rem] uppercase tracking-[0.08em] opacity-60 truncate">
                {gettext("Operação Sorriso")}
              </span>
            </span>
          </.link>
          <!-- Where you are, for the screen size that has no menu bar to read it
               off. On a phone the hamburger hides the nav, so without this the
               section colour would be the only clue and a colour alone is not a
               name. -->
          <span
            :if={@section && section_label(@current_path)}
            class="lg:hidden ml-3 hidden sm:inline-flex items-center gap-1.5 text-sm opacity-80 min-w-0"
          >
            <span class="section-mark h-3.5 w-0.5 rounded-full" aria-hidden="true" />
            <span class="truncate">{section_label(@current_path)}</span>
          </span>
        </div>

        <nav
          :if={@current_scope}
          class="hidden lg:flex items-center gap-1"
          aria-label={gettext("Main")}
        >
          <.nav_group :for={group <- nav_groups()} group={group} current_path={@current_path} />
        </nav>

        <div class="flex-none flex items-center gap-1">
          <!-- Only for somebody who is allowed to see the amounts in the first
               place: offering to hide what was never sent would be theatre. -->
          <button
            :if={@current_scope && @sees_money?}
            type="button"
            class="btn btn-ghost btn-square"
            phx-click={JS.dispatch("phx:toggle-money")}
            aria-label={gettext("Show or hide the amounts")}
            title={gettext("Show or hide the amounts")}
          >
            <.icon name="hero-eye" class="size-5 money-real" />
            <.icon name="hero-eye-slash" class="size-5 money-mask" />
          </button>

          <details :if={@current_scope} class="dropdown dropdown-end lg:hidden">
            <summary class="btn btn-ghost" aria-label={gettext("Open menu")}>
              <.icon name="hero-bars-3" class="size-5" />
            </summary>
            <div class="dropdown-content z-50 mt-2 w-64 rounded-box bg-base-100 shadow-lg border border-base-300 max-h-[80vh] overflow-y-auto text-base-content">
              <ul :for={group <- nav_groups()} class="menu w-full" data-section={group.section}>
                <li class="menu-title section-label">{group.label}</li>
                <li :for={item <- group.items}>
                  <.link navigate={item.path} class={nav_item_class(@current_path, item.path)}>
                    <.icon name={item.icon} class="size-5 opacity-70" />
                    {item.label}
                  </.link>
                </li>
              </ul>
            </div>
          </details>

          <details :if={@current_scope} class="dropdown dropdown-end">
            <summary class="btn btn-ghost" aria-label={gettext("Account")}>
              <.icon name="hero-user-circle" class="size-5" />
            </summary>
            <!-- The theme toggle is a control, not a menu entry, so it sits beside
               the list rather than inside it: daisyUI restyles every direct child
               of a menu item as `display: grid`, which silently overrode the
               toggle's own flex layout and threw its sliding indicator out of
               line with the buttons. -->
            <div class="dropdown-content z-50 mt-2 w-56 rounded-box bg-base-100 shadow-lg border border-base-300 text-base-content">
              <ul class="menu w-full">
                <li class="menu-title truncate">{@current_scope.user.email}</li>
                <li><.link navigate={~p"/users/settings"}>{gettext("Settings")}</.link></li>
                <li :if={admin?(@current_scope)}>
                  <.link navigate={~p"/admin/users"}>{gettext("Manage users")}</.link>
                </li>
              </ul>

              <div class="px-4 pb-1">
                <p class="text-xs font-semibold opacity-60">{gettext("Appearance")}</p>
                <.theme_toggle />
              </div>

              <!-- A menu entry like every other one in this panel, rather than a
                   cluster of pills wrapping under a paragraph. The banner
                   explains read-only at the moment it starts mattering, which is
                   after the click, so it does not need explaining here. -->
              <ul :if={admin?(@current_scope)} class="menu w-full">
                <li class="menu-title">{gettext("View as")}</li>
                <li :for={role <- ~w(manager logistics auditor)}>
                  <.link href={~p"/users/view-as?role=#{role}"} method="post">
                    {EstoqueOSWeb.ViewAsController.label(role)}
                  </.link>
                </li>
              </ul>

              <ul class="menu w-full">
                <li>
                  <.link href={~p"/users/log-out"} method="delete">{gettext("Log out")}</.link>
                </li>
              </ul>
            </div>
          </details>

          <div :if={is_nil(@current_scope)} class="flex items-center gap-1">
            <.link navigate={~p"/users/log-in"} class="btn btn-sm">{gettext("Log in")}</.link>
          </div>
        </div>
      </header>

      <!-- Impossible to be in this mode and not know it. A borrowed role changes
           what the whole app shows, and an admin who forgets they are wearing
           one will file a bug against a screen that is behaving correctly. -->
      <div
        :if={@current_scope && Scope.viewing_as?(@current_scope)}
        class="bg-warning text-warning-content px-4 sm:px-6 lg:px-8 py-2"
        role="status"
      >
        <div class="mx-auto max-w-6xl flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <.icon name="hero-eye" class="size-4 shrink-0" />
          <span class="font-semibold">
            {gettext("Seeing the app as %{role}",
              role: EstoqueOSWeb.ViewAsController.label(Scope.effective_role(@current_scope))
            )}
          </span>
          <span class="opacity-80">{gettext("Read-only: nothing can be recorded.")}</span>
          <.link
            href={~p"/users/view-as"}
            method="delete"
            class="btn btn-xs btn-neutral ml-auto"
          >
            {gettext("Back to my account")}
          </.link>
        </div>
      </div>

      <main class="px-4 pt-6 pb-12 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-6xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The mark — PROVISIONAL, like the palette it sits in.

  Operação Sorriso has an official logo and we do not have the file (see
  PRODUCT.md), so this stands in and must never be presented as theirs. It is a
  box drawn as an open carton, because a box is the noun this whole system turns
  on: everything here is something in a box, going somewhere, coming back.

  Deliberately geometric and one colour, so replacing it is dropping in an
  `<img>` and deleting this function.
  """
  def mark(assigns) do
    ~H"""
    <span class="grid size-9 shrink-0 place-items-center rounded-[0.5rem] bg-primary text-primary-content">
      <svg viewBox="0 0 24 24" fill="none" class="size-5" aria-hidden="true">
        <path
          d="M3 7.5 12 3l9 4.5v9L12 21l-9-4.5v-9Z"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linejoin="round"
        />
        <path d="M3 7.5 12 12l9-4.5M12 12v9" stroke="currentColor" stroke-width="1.75" />
      </svg>
    </span>
    """
  end

  # Only a real admin, and not one already standing in another role: the picker
  # must not offer a way to swap shoes while wearing somebody else's.
  defp admin?(%Scope{user: %EstoqueOS.Accounts.User{role: "admin"}, view_as: nil}), do: true
  defp admin?(_scope), do: false

  attr :group, :map, required: true
  attr :current_path, :string, default: nil

  defp nav_group(assigns) do
    ~H"""
    <details class="dropdown" data-section={@group.section}>
      <summary class={[
        "btn btn-ghost gap-1.5",
        group_active?(@current_path, @group) && "btn-active"
      ]}>
        <.icon name={@group.icon} class="size-5" />
        {@group.label}
        <.icon name="hero-chevron-down-micro" class="size-3 opacity-60" />
      </summary>
      <ul class="dropdown-content z-50 mt-2 w-64 menu rounded-box bg-base-100 shadow-lg border border-base-300 text-base-content">
        <li :for={item <- @group.items}>
          <.link navigate={item.path} class={nav_item_class(@current_path, item.path)}>
            <.icon name={item.icon} class="size-5 opacity-70" />
            {item.label}
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  # Grouped the way the operation itself is sequenced: what comes in, what we
  # hold, what goes out, and what is checked. Ten flat links were unusable on
  # the phone this gets used on inside a warehouse.
  # Grouped by who is doing the work, not by what the code calls things.
  # "Operação" is the hands-on menu: the flows someone performs standing up, in
  # a warehouse or a mission room, usually on a phone.
  #
  # `section` is the group's colour identity, and it is a stable English key
  # rather than the translated label: the CSS keys off it, so a translation must
  # never repaint the app.
  defp nav_groups do
    [
      %{
        section: "incoming",
        label: gettext("Incoming"),
        icon: "hero-arrow-down-tray",
        items: [
          %{label: gettext("Invoices"), path: ~p"/invoices", icon: "hero-document-text"},
          %{
            label: gettext("Manual entry"),
            path: ~p"/entry",
            icon: "hero-inbox-arrow-down"
          },
          %{
            label: gettext("Import data"),
            path: ~p"/stock/spreadsheet",
            icon: "hero-table-cells"
          }
        ]
      },
      %{
        section: "operation",
        label: gettext("Operation"),
        icon: "hero-clipboard-document-check",
        items: [
          # First, because it is the first thing that happens to goods after
          # they arrive — and because it is the entry the operator was missing.
          %{
            label: gettext("Conference"),
            path: ~p"/conferences",
            icon: "hero-clipboard-document-list"
          },
          %{label: gettext("Count boxes"), path: ~p"/audit", icon: "hero-check-circle"},
          %{label: gettext("Write off"), path: ~p"/issue", icon: "hero-arrow-up-tray"},
          %{label: gettext("Load-out"), path: ~p"/load-out", icon: "hero-truck"},
          %{label: gettext("Mission return"), path: ~p"/returns", icon: "hero-arrow-uturn-left"}
        ]
      },
      %{
        section: "stock",
        label: gettext("Stock"),
        icon: "hero-archive-box",
        items: [
          %{label: gettext("Stock"), path: ~p"/stock", icon: "hero-squares-2x2"},
          %{label: gettext("Boxes"), path: ~p"/boxes", icon: "hero-cube"},
          %{label: gettext("Locations"), path: ~p"/locations", icon: "hero-map-pin"},
          %{label: gettext("Kits"), path: ~p"/kits", icon: "hero-rectangle-stack"}
        ]
      },
      %{
        section: "reports",
        label: gettext("Reports"),
        icon: "hero-chart-bar",
        items: [
          %{
            label: gettext("Audit report"),
            path: ~p"/reports/audit",
            icon: "hero-clipboard-document-list"
          },
          %{label: gettext("Manual issues"), path: ~p"/issues", icon: "hero-arrow-up-tray"},
          %{label: gettext("Missions"), path: ~p"/missions", icon: "hero-map"}
        ]
      }
    ]
  end

  @doc """
  Which section of the operation a path belongs to, and what that section is
  called.

  Derived from the menu rather than declared per screen: the nav is already the
  statement of how this system is divided, and a screen that had to name its own
  section would be free to disagree with the menu it sits under.

  A path the menu does not know — a detail screen like `/boxes/42`, or the
  account settings — falls back to its longest matching prefix, and then to
  nothing. A page with no section still renders; it simply keeps the default
  blue rather than borrowing a colour it has no claim to.
  """
  def active_section(nil), do: nil

  def active_section(current_path) do
    case matching_group(current_path) do
      nil -> nil
      group -> group.section
    end
  end

  @doc "The section's own name, for the eyebrow above a page title."
  def section_label(nil), do: nil

  def section_label(current_path) do
    case matching_group(current_path) do
      nil -> nil
      group -> group.label
    end
  end

  # Longest prefix wins, so "/invoices/import" is claimed by the entry for
  # "/invoices/import" rather than by "/invoices".
  defp matching_group(current_path) do
    nav_groups()
    |> Enum.flat_map(fn group ->
      Enum.map(group.items, &{String.length(&1.path), &1.path, group})
    end)
    |> Enum.filter(fn {_len, path, _group} -> prefix?(current_path, path) end)
    |> Enum.max_by(fn {len, _path, _group} -> len end, fn -> nil end)
    |> case do
      nil -> nil
      {_len, _path, group} -> group
    end
  end

  # "/boxes" claims "/boxes/42" but must not claim "/boxes-archive", and the
  # root path claims only itself.
  defp prefix?(current_path, "/"), do: current_path == "/"

  defp prefix?(current_path, path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end

  # A group lights up for anything beneath it, so "/boxes/42" keeps Estoque
  # marked. It asks `matching_group/1` rather than testing its own items,
  # because "/stock/spreadsheet" sits under Entradas while "/stock" sits under
  # Estoque — testing item by item would light both.
  defp group_active?(nil, _group), do: false

  defp group_active?(current_path, group) do
    matching_group(current_path) == group
  end

  # "/invoices" must light up on "/invoices/42" but not on "/invoices/import",
  # which belongs to its own entry.
  defp nav_active?(nil, _path), do: false
  defp nav_active?(current_path, path), do: current_path == path

  defp nav_item_class(current_path, path) do
    if nav_active?(current_path, path), do: "menu-active font-medium", else: nil
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative mt-1 flex w-full flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
