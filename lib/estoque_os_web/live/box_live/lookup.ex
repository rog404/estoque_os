defmodule EstoqueOSWeb.BoxLive.Lookup do
  @moduledoc """
  What is in a box, for whoever is holding it.

  Public on purpose, and for now a field test: the person with a box in their
  hands at a mission site is not always somebody with an account, and the label
  on the box is all they have. Reading is all this screen does — every write
  still lives behind a login. It shows the whole content, controlled-substance
  flag included, to anyone with the code; that exposure is a known, accepted
  call while this is a test, and the screen is slated to move inside the
  authenticated routes later.

  The camera reads a QR label when the browser can (`BarcodeDetector`, which a
  phone's Chrome has); typing the code is the path that always works, so the
  scan button degrades into a hint instead of a wall.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("What is in this box"))
     |> assign(:code, "")
     |> assign(:searched, false)
     |> assign(:box, nil)
     |> assign(:contents, [])
     |> assign(:scanning, false)
     |> assign(:camera_error, nil)}
  end

  # A QR label can encode the full URL of this page; the code rides in as a
  # query param and the answer is already on screen when the page opens.
  @impl true
  def handle_params(%{"code" => code}, _uri, socket), do: {:noreply, lookup(socket, code)}
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("lookup", %{"code" => code}, socket) do
    {:noreply, lookup(socket, code)}
  end

  def handle_event("scan", _params, socket) do
    {:noreply, socket |> assign(:scanning, true) |> assign(:camera_error, nil)}
  end

  def handle_event("stop_scan", _params, socket) do
    {:noreply, assign(socket, :scanning, false)}
  end

  def handle_event("scanned", %{"code" => text}, socket) do
    {:noreply, socket |> assign(:scanning, false) |> lookup(code_from_qr(text))}
  end

  def handle_event("camera_error", %{"reason" => reason}, socket) do
    {:noreply,
     socket |> assign(:scanning, false) |> assign(:camera_error, camera_message(reason))}
  end

  defp lookup(socket, code) do
    socket = socket |> assign(:code, String.trim(to_string(code))) |> assign(:searched, true)

    case Locations.get_box_by_code(code) do
      nil ->
        socket |> assign(:box, nil) |> assign(:contents, [])

      box ->
        # By id again: the lookup by code does not carry the location the
        # header prints.
        box = Locations.get_box!(box.id)
        socket |> assign(:box, box) |> assign(:contents, Locations.box_contents(box))
    end
  end

  # The label may carry the bare code or a link to this page; both answer.
  defp code_from_qr(text) do
    text = String.trim(to_string(text))
    uri = URI.parse(text)

    cond do
      uri.scheme not in ["http", "https"] -> text
      code = uri.query && URI.decode_query(uri.query)["code"] -> code
      true -> uri.path |> to_string() |> Path.basename()
    end
  end

  defp camera_message("unsupported"),
    do: gettext("This browser cannot read QR codes here — type the code instead.")

  defp camera_message(_denied),
    do: gettext("The camera was refused — type the code instead.")

  defp verified_label(%{last_verified_at: nil}), do: gettext("never counted")

  defp verified_label(%{last_verified_at: verified_at}) do
    gettext("counted on %{date}", date: date(verified_at))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-xl space-y-6">
        <.header>
          {gettext("What is in this box")}
          <:subtitle>
            {gettext("Scan the label's QR code or type the box code.")}
          </:subtitle>
        </.header>

        <form id="lookup-form" phx-submit="lookup" class="flex items-center gap-2">
          <input
            type="text"
            name="code"
            value={@code}
            placeholder={gettext("Box code, like CX01")}
            autocapitalize="characters"
            autocomplete="off"
            spellcheck="false"
            class="input input-bordered input-lg flex-1 uppercase"
            aria-label={gettext("Box code")}
          />
          <.button variant="primary" class="btn-lg">
            {gettext("Search")}
          </.button>
        </form>

        <div class="flex items-center gap-2">
          <.button :if={!@scanning} phx-click="scan" class="btn-sm">
            <.icon name="hero-qr-code" class="size-5" /> {gettext("Scan the QR code")}
          </.button>
          <.button :if={@scanning} phx-click="stop_scan" class="btn-sm">
            {gettext("Stop the camera")}
          </.button>
          <span :if={@camera_error} class="text-sm text-error">{@camera_error}</span>
        </div>

        <div :if={@scanning} id="qr-scanner" phx-hook=".QrScanner" class="space-y-2">
          <video playsinline muted class="w-full rounded-box border border-base-300"></video>
          <p class="text-sm opacity-70">{gettext("Point the camera at the label's QR code.")}</p>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".QrScanner">
          export default {
            async mounted() {
              const video = this.el.querySelector("video")

              if (!("BarcodeDetector" in window)) {
                this.pushEvent("camera_error", {reason: "unsupported"})
                return
              }

              try {
                this.stream = await navigator.mediaDevices.getUserMedia({
                  video: {facingMode: "environment"},
                  audio: false
                })
              } catch (_error) {
                this.pushEvent("camera_error", {reason: "denied"})
                return
              }

              video.srcObject = this.stream
              await video.play()

              const detector = new BarcodeDetector({formats: ["qr_code"]})

              this.timer = setInterval(async () => {
                if (video.readyState < 2) return

                try {
                  const codes = await detector.detect(video)

                  if (codes.length > 0 && codes[0].rawValue) {
                    clearInterval(this.timer)
                    this.pushEvent("scanned", {code: codes[0].rawValue})
                  }
                } catch (_error) {
                  // A frame that fails to decode is not an error worth stopping for.
                }
              }, 250)
            },

            destroyed() {
              if (this.timer) clearInterval(this.timer)
              if (this.stream) this.stream.getTracks().forEach((track) => track.stop())
            }
          }
        </script>

        <.panel :if={@box} title={gettext("Box %{code}", code: @box.code)} flush>
          <p class="px-4 pb-2 text-sm opacity-70">
            {@box.location.name} · {verified_label(@box)}
          </p>

          <.data_table rows={@contents}>
            <:empty>
              <.empty
                title={gettext("This box is empty.")}
                note={gettext("Nothing is recorded inside it right now.")}
              />
            </:empty>

            <:col :let={row} label={gettext("Product")} emphasis={:identity}>
              {row.product}
              <.status :if={row.controlled} kind={:controlled} />
            </:col>
            <:col :let={row} label={gettext("Lot")}>{row.lot_number || gettext("unknown")}</:col>
            <:col :let={row} label={gettext("Expiry")}>{date(row.expires_on)}</:col>
            <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
              <span class="figure">{quantity(row.quantity)}</span>
            </:col>
          </.data_table>
        </.panel>

        <.empty
          :if={@searched and is_nil(@box)}
          title={gettext("No box answers to \"%{code}\".", code: @code)}
          note={gettext("Check the label — codes look like CX01.")}
        />
      </div>
    </Layouts.app>
    """
  end
end
