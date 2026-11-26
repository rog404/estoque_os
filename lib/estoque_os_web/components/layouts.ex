defmodule EstoqueOSWeb.Layouts do
  @moduledoc """
  Layouts, the navigation menu and flash group.
  """
  use EstoqueOSWeb, :html

  alias EstoqueOS.Accounts.Scope

  embed_templates "layouts/*"

  @doc """
  Renders the app layout.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_path, :string, default: nil, doc: "path of the page being shown, to mark the nav"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:groups, visible_groups(assigns[:current_scope]))
      |> assign(:sees_money?, EstoqueOSWeb.UserAuth.sees_money?(assigns[:current_scope]))

    assigns = assign(assigns, :section, active_section(assigns[:current_path], assigns.groups))

    ~H"""
    <div data-section={@section}>
      <header class="app-bar navbar gap-2 px-4 sm:px-6 lg:px-8">
        <div class="flex-1 min-w-0">
          <.link
            navigate={same_live_session?(@current_path, ~p"/") && ~p"/"}
            href={not same_live_session?(@current_path, ~p"/") && ~p"/"}
            class="flex w-fit items-center gap-2.5"
            aria-label={gettext("Home")}
          >
            <.mark />
          </.link>
          <span
            :if={@section && section_label(@current_path, @groups)}
            class="lg:hidden ml-3 hidden sm:inline-flex items-center gap-1.5 text-sm opacity-80 min-w-0"
          >
            <span class="section-mark h-3.5 w-0.5 rounded-full" aria-hidden="true" />
            <span class="truncate">{section_label(@current_path, @groups)}</span>
          </span>
        </div>

        <nav
          :if={@current_scope}
          class="hidden lg:flex items-center gap-1"
          aria-label={gettext("Main")}
        >
          <.nav_group
            :for={group <- @groups}
            group={group}
            groups={@groups}
            current_path={@current_path}
          />
        </nav>

        <div class="flex-none flex items-center gap-1">
          <.live_component
            :if={@current_scope && EstoqueOS.Alerts.visible_to?(@current_scope)}
            module={EstoqueOSWeb.AlertsBell}
            id="alerts-bell"
            current_scope={@current_scope}
          />

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
              <ul :for={group <- @groups} class="menu w-full" data-section={group.section}>
                <li class="menu-title section-label">{group.label}</li>
                <li :for={item <- group.items}>
                  <.nav_link item={item} current_path={@current_path} />
                </li>
              </ul>
            </div>
          </details>

          <details :if={@current_scope} class="dropdown dropdown-end">
            <summary class="btn btn-ghost" aria-label={gettext("Account")}>
              <.icon name="hero-user-circle" class="size-5" />
            </summary>
            <%!-- Theme toggle sits beside the menu list: daisyUI makes a menu item's direct children `display: grid`, breaking its flex layout. --%>
            <div class="dropdown-content z-50 mt-2 w-56 rounded-box bg-base-100 shadow-lg border border-base-300 text-base-content">
              <ul class="menu w-full">
                <li class="menu-title truncate">{@current_scope.user.email}</li>
                <li><.link navigate={~p"/users/settings"}>{gettext("Settings")}</.link></li>
                <li :if={admin?(@current_scope)}>
                  <.link navigate={~p"/admin/users"}>{gettext("Manage users")}</.link>
                </li>
              </ul>

              <div class="px-4 pb-1">
                <p class="eyebrow text-base-content/60">{gettext("Appearance")}</p>
                <.theme_toggle />
              </div>

              <ul :if={admin?(@current_scope)} class="menu w-full">
                <li class="menu-title">{gettext("View as")}</li>
                <li :for={role <- ~w(manager marketing logistics auditor)}>
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
  The mark, PROVISIONAL: a stand-in for the organisation's official logo (see
  PRODUCT.md), never to be presented as theirs. Replace with an `<img>`.
  """
  def mark(assigns) do
    ~H"""
    <img
      src={~p"/images/icon.png"}
      alt=""
      aria-hidden="true"
      width="36"
      height="36"
      class="size-9 shrink-0 rounded-[0.5rem]"
    />
    """
  end

  # Not an admin already viewing as another role: no nested view-as.
  defp admin?(%Scope{user: %EstoqueOS.Accounts.User{role: "admin"}, view_as: nil}), do: true
  defp admin?(_scope), do: false

  attr :group, :map, required: true
  attr :current_path, :string, default: nil
  attr :groups, :list, required: true

  defp nav_group(assigns) do
    ~H"""
    <details class="dropdown" data-section={@group.section}>
      <summary class={[
        "btn btn-ghost gap-1.5",
        group_active?(@current_path, @group, @groups) && "btn-active"
      ]}>
        <.icon name={@group.icon} class="size-5" />
        {@group.label}
        <.icon name="hero-chevron-down-micro" class="size-3 opacity-60" />
      </summary>
      <ul class="dropdown-content z-50 mt-2 w-64 menu rounded-box bg-base-100 shadow-lg border border-base-300 text-base-content">
        <li :for={item <- @group.items}>
          <.nav_link item={item} current_path={@current_path} />
        </li>
      </ul>
    </details>
    """
  end

  attr :item, :map, required: true
  attr :current_path, :string, default: nil

  # `navigate` across a `live_session` falls back to a full reload after a wasted
  # socket round trip, so cross-session links use `href`. The session of a path
  # is read from the router, not declared here.
  defp nav_link(assigns) do
    assigns = assign(assigns, :live?, same_live_session?(assigns.current_path, assigns.item.path))

    ~H"""
    <.link
      navigate={@live? && @item.path}
      href={not @live? && @item.path}
      class={nav_item_class(@current_path, @item.path)}
    >
      <.icon name={@item.icon} class="size-5 opacity-70" />
      {@item.label}
    </.link>
    """
  end

  defp same_live_session?(nil, _to), do: false

  defp same_live_session?(from, to) do
    case {live_session_of(from), live_session_of(to)} do
      {nil, _} -> false
      {_, nil} -> false
      {same, same} -> true
      _ -> false
    end
  end

  defp live_session_of(path) do
    case Phoenix.Router.route_info(EstoqueOSWeb.Router, "GET", without_query(path), "") do
      %{phoenix_live_view: {_view, _action, _opts, %{name: name}}} -> name
      _ -> nil
    end
  end

  # `section` is a stable English key, not the translated label: the CSS keys
  # off it, so a translation must never repaint the app.
  defp nav_groups do
    [
      %{
        section: "incoming",
        label: gettext("Incoming"),
        icon: "hero-arrow-down-tray",
        items: [
          %{
            label: gettext("Invoices"),
            path: ~p"/invoices",
            icon: "hero-document-text",
            roles: ~w(admin manager marketing auditor)
          },
          %{
            label: gettext("Manual entries recorded"),
            path: ~p"/entries",
            icon: "hero-clipboard-document-list",
            roles: :everyone
          },
          %{
            label: gettext("Manual entry"),
            path: ~p"/entry",
            icon: "hero-inbox-arrow-down",
            roles: ~w(admin manager marketing logistics)
          }
        ]
      },
      %{
        section: "operation",
        label: gettext("Operation"),
        icon: "hero-clipboard-document-check",
        items: [
          %{
            label: gettext("Conference"),
            path: ~p"/conferences",
            icon: "hero-clipboard-document-list",
            roles: ~w(admin manager logistics marketing)
          },
          %{
            label: gettext("Write off"),
            path: ~p"/issue",
            icon: "hero-arrow-up-tray",
            roles: ~w(admin manager marketing)
          },
          %{
            label: gettext("Send a load"),
            path: ~p"/load-out",
            icon: "hero-truck",
            roles: ~w(admin manager logistics marketing)
          },
          %{
            label: gettext("Receive a load"),
            path: ~p"/returns",
            icon: "hero-arrow-uturn-left",
            roles: ~w(admin manager logistics marketing)
          }
        ]
      },
      %{
        section: "stock",
        label: gettext("Stock"),
        icon: "hero-archive-box",
        items: [
          # Same screen for marketing, narrowed to their stock by the scope.
          %{
            label: gettext("Stock"),
            path: ~p"/stock",
            icon: "hero-squares-2x2",
            roles: :everyone
          },
          # Roles mirror the `:warehouse_read` live_session; `nav_roles_test.exs`
          # holds the two together.
          %{
            label: gettext("Boxes"),
            path: ~p"/boxes",
            icon: "hero-cube",
            roles: ~w(admin manager logistics auditor marketing)
          },
          %{
            label: gettext("Look up a box"),
            path: ~p"/boxes/lookup",
            icon: "hero-magnifying-glass",
            roles: ~w(admin manager logistics auditor marketing)
          },
          %{
            label: gettext("Locations"),
            path: ~p"/locations",
            icon: "hero-map-pin",
            roles: ~w(admin manager logistics auditor marketing)
          },
          %{
            label: gettext("Kits"),
            path: ~p"/kits",
            icon: "hero-rectangle-stack",
            roles: ~w(admin manager logistics auditor marketing)
          },
          # Import/export of the stock itself belongs here, not under Reports.
          %{
            label: gettext("Spreadsheets"),
            path: ~p"/stock/sheets",
            icon: "hero-table-cells",
            roles: ~w(admin manager)
          }
        ]
      },
      %{
        section: "reports",
        label: gettext("Reports"),
        icon: "hero-chart-bar",
        items: [
          %{
            label: gettext("Sales"),
            path: ~p"/reports/sales",
            icon: "hero-banknotes",
            roles: ~w(admin manager marketing auditor)
          },
          # Marketing included: a mission box mixes both stocks.
          %{
            label: gettext("In transit"),
            path: ~p"/reports/transit",
            icon: "hero-truck",
            roles: ~w(admin manager logistics auditor marketing)
          },
          %{
            label: gettext("Audit report"),
            path: ~p"/reports/audit",
            icon: "hero-clipboard-document-list",
            roles: ~w(admin manager logistics auditor marketing)
          },
          %{
            label: gettext("Manual issues"),
            path: ~p"/issues",
            icon: "hero-arrow-up-tray",
            roles: :everyone
          },
          %{
            label: gettext("Missions"),
            path: ~p"/missions",
            icon: "hero-map",
            roles: ~w(admin manager logistics auditor marketing)
          }
        ]
      }
    ]
  end

  @doc """
  The menu as one role sees it: groups with nothing in them do not appear.

  Presentation, never the gate — the router is. `roles` mirrors the
  `live_session` of each path; `nav_roles_test.exs` holds the two together.
  """
  def visible_groups(scope) do
    role = Scope.effective_role(scope)

    nav_groups()
    |> Enum.map(&%{&1 | items: Enum.filter(&1.items, fn item -> allowed?(item, role) end)})
    |> Enum.reject(&(&1.items == []))
  end

  @doc """
  Whether this scope may open the given menu path, so shortcuts and the menu
  answer from the same table.
  """
  def may_access?(scope, path) do
    role = Scope.effective_role(scope)
    wanted = without_query(path)

    Enum.any?(all_items(), &(without_query(&1.path) == wanted and allowed?(&1, role)))
  end

  # Menu paths may carry a query (marketing entries); it never affects role,
  # section or `live_session`.
  defp without_query(path), do: path |> to_string() |> String.split("?") |> hd()

  defp allowed?(_item, nil), do: false
  defp allowed?(%{roles: :everyone}, _role), do: true
  defp allowed?(%{roles: roles}, role), do: role in roles

  defp all_items, do: Enum.flat_map(nav_groups(), & &1.items)

  @doc """
  Which menu section a path belongs to, derived from the menu rather than
  declared per screen.

  An unknown path falls back to its longest matching prefix, then to nothing
  (the page keeps the default colour).
  """
  def active_section(current_path, groups \\ nav_groups())

  def active_section(nil, _groups), do: nil

  def active_section(current_path, groups) do
    case matching_group(current_path, groups) do
      nil -> nil
      group -> group.section
    end
  end

  @doc "The section's own name, for the eyebrow above a page title."
  def section_label(current_path, groups \\ nav_groups())

  def section_label(nil, _groups), do: nil

  def section_label(current_path, groups) do
    case matching_group(current_path, groups) do
      nil -> nil
      group -> group.label
    end
  end

  # Longest prefix wins. Matched against the groups this role can see, since
  # `/stock` belongs to two entries and the answer depends on who is looking.
  defp matching_group(current_path, groups) do
    groups
    |> Enum.flat_map(fn group ->
      Enum.map(group.items, &{String.length(&1.path), without_query(&1.path), group})
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

  # Asks `matching_group/2` rather than testing its own items, which would
  # light two groups for paths like "/stock/sheets" vs "/stock".
  defp group_active?(nil, _group, _groups), do: false

  defp group_active?(current_path, group, groups) do
    matching_group(current_path, groups) == group
  end

  # "/invoices" must light up on "/invoices/42" but not on "/invoices/import",
  # which belongs to its own entry.
  defp nav_active?(nil, _path), do: false
  defp nav_active?(current_path, path), do: current_path == without_query(path)

  defp nav_item_class(current_path, path) do
    if nav_active?(current_path, path), do: "menu-active font-medium", else: nil
  end

  @doc """
  Shows the flash group with standard titles and content.

  One fixed container holds every notice, so two `toast`s never overlap in the
  same corner. Each notice folds away on its own clock so the ones above slide
  down instead of jumping. Bottom, not top, to leave the navigation bar clear.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      class="toast toast-bottom toast-end z-50 max-w-full items-end gap-2"
      aria-live="polite"
    >
      <.flash kind={:info} flash={@flash} dismiss_after={info_ms()} />
      <.flash kind={:error} flash={@flash} dismiss_after={error_ms()} />

      <%!-- No countdown on these two: they are connection state, not announcements. --%>
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

  # Long enough to read twice, standing up. Errors are instructions and get more
  # than double.
  defp info_ms, do: 6_000
  defp error_ms, do: 14_000

  @doc """
  Dark vs light theme toggle; root.html.heex applies the theme before page load.
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
