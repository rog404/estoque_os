defmodule EstoqueOSWeb.AlertsBell do
  @moduledoc """
  What is open, on every screen, with the two things that can be closed
  closable from here.

  It is a `LiveComponent` and not a function component for one reason: it takes
  actions. A function component in the layout would have to send its events to
  whichever LiveView happens to be underneath, so every one of the twenty-six
  screens would need a handler for something that is not theirs. A component
  targets itself.

  That also means the layout's `:guard_writes` hook never sees these events —
  hooks attached to a LiveView do not run for events a component handles — so
  the authorization is inside `Alerts.acknowledge_count/3` and
  `Alerts.acknowledge_lot/2`, where it belongs anyway. They refuse anyone
  outside `roles_that_plan/0`, and refuse an admin wearing somebody else's role:
  an acknowledgement carries a name, and it has to be the name of whoever
  actually looked.
  """

  use EstoqueOSWeb, :live_component

  alias EstoqueOS.Alerts
  alias EstoqueOSWeb.Movement

  @preview 4

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:pending, Alerts.pending(scope))
    |> assign(:counts, Alerts.list_open_counts(limit: @preview))
    |> assign(:lots, Alerts.list_open_lots(scope, limit: @preview))
    |> assign(:may_acknowledge?, Alerts.may_acknowledge?(scope))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :total, Enum.sum(Enum.map(assigns.pending, & &1.count)))

    ~H"""
    <div>
      <details class="dropdown dropdown-end">
        <summary
          class="btn btn-ghost btn-square relative"
          aria-label={gettext("What needs attention")}
          title={gettext("What needs attention")}
        >
          <.icon name="hero-bell" class="size-5" />
          <!-- The number, not a dot. "Something is wrong" is not information;
               "four things are open" is, and it is the difference between a
               badge people learn to ignore and one they open. -->
          <span
            :if={@total > 0}
            class="absolute -top-0.5 -right-0.5 badge badge-xs badge-warning font-semibold"
          >
            {@total}
          </span>
        </summary>

        <div class="dropdown-content z-50 mt-2 w-80 sm:w-96 max-w-[calc(100vw-1.5rem)] rounded-box bg-base-100 shadow-lg border border-base-300 text-base-content max-h-[80vh] overflow-y-auto">
          <div class="px-4 py-3 border-b border-base-200">
            <p class="font-semibold">{gettext("What needs attention")}</p>
            <p :if={@total == 0} class="text-sm text-base-content/70">
              {gettext("Nothing open. The stock agrees with itself.")}
            </p>
          </div>

          <!-- The two that can be closed come first and come as *items*, because
               closing one is the whole point of being here. The rest are counts
               with a way in. -->
          <section :if={@counts != []} class="px-4 py-3 border-b border-base-200 space-y-2">
            <p class="text-sm font-medium">
              {gettext("Counts that did not agree")}
            </p>
            <div :for={row <- @counts} class="text-sm">
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate">
                    {row.box || gettext("conference")} · {Enum.join(row.products, ", ")}
                  </p>
                  <p class="text-xs text-base-content/70">
                    {Movement.reason_label(row.transaction.reason_code)} · {date(
                      row.transaction.occurred_at
                    )}
                  </p>
                </div>
                <button
                  :if={@may_acknowledge?}
                  type="button"
                  phx-click="acknowledge_count"
                  phx-value-id={row.transaction.id}
                  phx-target={@myself}
                  class="btn btn-xs btn-soft shrink-0"
                >
                  {gettext("Noted")}
                </button>
              </div>
            </div>
          </section>

          <section :if={@lots != []} class="px-4 py-3 border-b border-base-200 space-y-2">
            <p class="text-sm font-medium">{gettext("Goods with no lot data")}</p>
            <div :for={lot <- @lots} class="text-sm flex items-start justify-between gap-2">
              <div class="min-w-0">
                <p class="truncate">{lot.product}</p>
                <p class="text-xs text-base-content/70">
                  {gettext("arrived without a lot number")}
                </p>
              </div>
              <button
                :if={@may_acknowledge?}
                type="button"
                phx-click="acknowledge_lot"
                phx-value-id={lot.id}
                phx-target={@myself}
                class="btn btn-xs btn-soft shrink-0"
              >
                {gettext("Noted")}
              </button>
            </div>
          </section>

          <ul class="menu w-full">
            <li :for={alert <- @pending}>
              <.link navigate={alert.path} class="flex items-center justify-between gap-2">
                <span class="min-w-0 truncate">{label(alert.kind)}</span>
                <span class={["badge badge-sm shrink-0", tone(alert.severity)]}>
                  {alert.count}
                </span>
              </.link>
            </li>
          </ul>
        </div>
      </details>
    </div>
    """
  end

  @impl true
  def handle_event("acknowledge_count", %{"id" => id}, socket) do
    case Alerts.acknowledge_count(id, socket.assigns.current_scope) do
      {:ok, _transaction} -> {:noreply, load(socket)}
      {:error, _reason} -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("acknowledge_lot", %{"id" => id}, socket) do
    case Alerts.acknowledge_lot(id, socket.assigns.current_scope) do
      {:ok, _lot} -> {:noreply, load(socket)}
      {:error, _reason} -> {:noreply, refuse(socket)}
    end
  end

  defp refuse(socket) do
    put_flash(socket, :error, gettext("You don't have permission to do that."))
  end

  defp label(:counts), do: gettext("Counts that did not agree")
  defp label(:lots), do: gettext("Goods with no lot data")
  defp label(:expiring), do: gettext("Expiring soon")
  defp label(:below_minimum), do: gettext("Below the minimum")
  defp label(:stale_boxes), do: gettext("Boxes to recount")

  defp tone(:high), do: "badge-error"
  defp tone(:medium), do: "badge-warning"
  defp tone(:low), do: "badge-ghost"
end
