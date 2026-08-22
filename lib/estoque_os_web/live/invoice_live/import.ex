defmodule EstoqueOSWeb.InvoiceLive.Import do
  @moduledoc """
  Step 1 of the import: drop the supplier's XML in and see what we understood.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Invoices
  alias EstoqueOSWeb.StockLive

  @max_upload_size 8_000_000

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Validating an upload parses a file and writes nothing; `import` posts the
  invoice and its stock.
  """
  def viewer_events, do: ~w(validate cancel segment)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Import invoice"))
     |> assign(:error, nil)
     # Which stock this delivery is for. It starts on the one the person works
     # in — marketing imports marketing — and stays a choice, because a
     # coordinator does receive the other side's delivery now and then and
     # re-importing under the right stock is not a thing anybody can do twice.
     |> assign(:segment, Scope.default_segment(socket.assigns.current_scope) || "medical")
     |> assign(:max_upload_size, @max_upload_size)
     |> allow_upload(:xml,
       accept: ~w(.xml text/xml application/xml),
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-2xl space-y-6">
        <.header back_to={~p"/invoices"} back_label={gettext("Invoices")}>
          {gettext("Import invoice")}
          <:subtitle>
            {gettext("Upload the XML the supplier sent. The DANFE PDF is not needed.")}
          </:subtitle>
        </.header>

        <!-- Reading the XML is the first of three moves, and the one that
             changes nothing on its own. Saying so here is what keeps an
             operator from walking away believing the stock went up. -->
        <ol class="flex items-center gap-3 text-sm">
          <li class="flex items-center gap-2 font-medium">
            <span class="badge badge-primary badge-sm">1</span>
            {gettext("Read the XML")}
          </li>
          <.icon name="hero-chevron-right-micro" class="size-3 opacity-40" />
          <li class="flex items-center gap-2 opacity-60">
            <span class="badge badge-ghost badge-sm">2</span>
            {gettext("Confirm the items")}
          </li>
          <.icon name="hero-chevron-right-micro" class="size-3 opacity-40" />
          <li class="flex items-center gap-2 opacity-60">
            <span class="badge badge-ghost badge-sm">3</span>
            {gettext("Post to stock")}
          </li>
        </ol>

        <!-- Decided here rather than inferred from the lines afterwards. It is
             what a product created from this invoice is filed under, and it is
             what makes the invoice belong to the person who just uploaded it —
             at this moment not one line has a product yet, so "which stock is
             this" has no other answer to read. -->
        <fieldset class="rounded-lg border border-base-300 p-4">
          <legend class="px-2 text-sm font-medium">{gettext("Stock")}</legend>

          <div role="tablist" class="tabs tabs-box w-fit">
            <button
              :for={segment <- Product.segments()}
              type="button"
              role="tab"
              phx-click="segment"
              phx-value-segment={segment}
              aria-selected={to_string(@segment == segment)}
              class={["tab", @segment == segment && "tab-active"]}
            >
              {StockLive.Index.segment_label(segment)}
            </button>
          </div>

          <p class="mt-2 text-sm text-base-content/70">
            {gettext(
              "Where the goods on this invoice belong, and the stock any new product created from it is filed under."
            )}
          </p>
        </fieldset>

        <form id="upload-form" phx-submit="import" phx-change="validate">
          <label
            class="flex flex-col items-center border-2 border-dashed border-base-300 hover:border-primary/60 rounded-lg p-10 text-center cursor-pointer transition-colors"
            phx-drop-target={@uploads.xml.ref}
          >
            <.icon name="hero-document-arrow-up" class="size-10 opacity-60" />
            <p class="mt-2 font-medium">{gettext("Drop the XML here or pick a file")}</p>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext("NF-e layout 4.00, up to %{size}", size: megabytes(@max_upload_size))}
            </p>
            <.live_file_input upload={@uploads.xml} class="sr-only" />
          </label>

          <div
            :for={entry <- @uploads.xml.entries}
            class="mt-4 rounded-lg border border-base-300 p-3"
          >
            <div class="flex items-center gap-3">
              <.icon name="hero-document-text" class="size-5 opacity-60 shrink-0" />
              <span class="truncate grow">{entry.client_name}</span>
              <span class="text-sm text-base-content/70 tabular-nums shrink-0">
                {megabytes(entry.client_size)}
              </span>
              <button
                type="button"
                class="btn btn-ghost btn-sm text-error hover:bg-error/10"
                phx-click="cancel"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove file")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <progress
              :if={entry.progress > 0 and entry.progress < 100}
              class="progress progress-primary mt-2 w-full"
              value={entry.progress}
              max="100"
            />

            <p :for={err <- upload_errors(@uploads.xml, entry)} class="text-error text-sm mt-1">
              {upload_error_to_string(err)}
            </p>
          </div>

          <p :if={@error} class="alert alert-error mt-4">{@error}</p>

          <div class="flex items-center justify-between gap-4 mt-6">
            <.link navigate={~p"/invoices"} class="link link-hover text-sm">
              {gettext("Back to invoices")}
            </.link>

            <.button
              variant="primary"
              disabled={not ready?(@uploads.xml)}
              phx-disable-with={gettext("Reading the invoice...")}
            >
              {gettext("Import")}
            </.button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, :error, nil)}

  def handle_event("segment", %{"segment" => segment}, socket) do
    {:noreply, assign(socket, :segment, segment(socket, segment))}
  end

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :xml, ref)}
  end

  def handle_event("import", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    case consume_uploaded_entries(socket, :xml, fn %{path: path}, _entry ->
           {:ok,
            path
            |> File.read!()
            |> Invoices.import_document(
              user_id: user_id,
              segment: socket.assigns.segment
            )}
         end) do
      [{:ok, invoice}] ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invoice imported. Now confirm the items."))
         |> push_navigate(to: ~p"/invoices/#{invoice}")}

      [{:error, :already_imported, invoice}] ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("This invoice had already been imported."))
         |> push_navigate(to: ~p"/invoices/#{invoice}")}

      [{:error, reason}] ->
        {:noreply, assign(socket, :error, error_message(reason))}

      [] ->
        {:noreply, assign(socket, :error, gettext("Pick an XML file first."))}
    end
  end

  defp error_message(:unsupported_document),
    do: gettext("This file is not an NF-e XML (layout 4.00).")

  defp error_message(:malformed_xml), do: gettext("The XML is malformed and could not be read.")

  defp error_message(:missing_access_key),
    do: gettext("The XML has no access key — is it really an NF-e?")

  defp error_message(_other), do: gettext("The invoice could not be imported.")

  # Nothing to send until a file is attached and the browser is happy with it.
  # Letting the button be pressed only to answer "pick a file first" is an
  # error the screen could have prevented.
  defp ready?(upload) do
    upload.entries != [] and Enum.all?(upload.entries, & &1.valid?)
  end

  # The role still wins: a marketing user asking for the surgical stock gets
  # their own back, the same rule every other screen applies.
  defp segment(socket, asked) do
    Scope.segment(socket.assigns.current_scope, asked) || "medical"
  end

  defp megabytes(bytes) do
    gettext("%{count} MB", count: Float.round(bytes / 1_000_000, 1))
  end

  defp upload_error_to_string(:too_large), do: gettext("File is too large.")
  defp upload_error_to_string(:not_accepted), do: gettext("Only XML files are accepted.")
  defp upload_error_to_string(:too_many_files), do: gettext("One invoice at a time, please.")
  defp upload_error_to_string(_), do: gettext("This file could not be uploaded.")
end
