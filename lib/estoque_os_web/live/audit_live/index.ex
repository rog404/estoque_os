defmodule EstoqueOSWeb.AuditLive.Index do
  @moduledoc """
  The guided mini-audit: which box to open first, and why.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Auditing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Mini-audit"))
     |> assign(:suggestions, Auditing.suggestions(limit: 12))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Mini-audit")}
        <:subtitle>
          {gettext("Count a few boxes well instead of pretending a full inventory is possible.")}
        </:subtitle>
      </.header>

      <p :if={@suggestions == []} class="mt-8 opacity-70">
        {gettext("No box holds stock yet.")}
      </p>

      <ol :if={@suggestions != []} class="mt-6 space-y-3">
        <li :for={{suggestion, index} <- Enum.with_index(@suggestions, 1)}>
          <div class="panel">
            <div class="panel-body flex flex-row items-center justify-between gap-4 flex-wrap">
              <div class="min-w-0">
                <p class="font-semibold">
                  <span class="opacity-50">{index}.</span>
                  {suggestion.box.code}
                  <span class="font-normal opacity-70">· {suggestion.box.location.name}</span>
                </p>
                <p class="text-sm opacity-70">
                  {gettext("%{quantity} units in %{count} lot(s)",
                    quantity: quantity(suggestion.quantity),
                    count: suggestion.positions
                  )}
                  <span :if={@sees_money? and Decimal.compare(suggestion.value, 0) == :gt}>
                    · {money(suggestion.value)}
                  </span>
                </p>
                <div class="flex flex-wrap gap-1 mt-1">
                  <span
                    :for={{kind, label} <- suggestion.reasons}
                    class={["badge badge-sm", reason_class(kind)]}
                  >
                    {label}
                  </span>
                </div>
              </div>

              <.link navigate={~p"/audit/#{suggestion.box}"} class="btn btn-primary btn-sm">
                {gettext("Count this box")}
              </.link>
            </div>
          </div>
        </li>
      </ol>
    </Layouts.app>
    """
  end

  defp reason_class(:controlled), do: "badge-error"
  defp reason_class(:expiring), do: "badge-warning"
  defp reason_class(:never_counted), do: "badge-ghost"
  defp reason_class(:stale), do: "badge-ghost"
end
