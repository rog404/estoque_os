// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/estoque_os"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// The nav groups are <details> elements, which stay open until you click the
// same summary again — so several menus overlapped each other. Opening one
// closes the rest, a click anywhere else closes all, Esc closes all, and
// following a link closes them before the page changes.
const closeMenus = (except) => {
  document.querySelectorAll("details.dropdown[open]").forEach((menu) => {
    if (menu !== except) menu.removeAttribute("open")
  })
}

window.addEventListener("click", (event) => {
  const summary = event.target.closest("details.dropdown > summary")
  if (summary) {
    closeMenus(summary.parentElement)
    return
  }

  if (event.target.closest("details.dropdown a")) {
    closeMenus()
    return
  }

  if (!event.target.closest("details.dropdown")) closeMenus()
})

window.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeMenus()
})

window.addEventListener("phx:page-loading-start", () => closeMenus())

// Irreversible ledger writes open a native <dialog>: focus trap and Esc for
// free, and the consequence is stated in the operation's own numbers before
// anything is written.
window.addEventListener("click", (event) => {
  const opener = event.target.closest("[data-confirm-open]")
  if (opener) {
    event.preventDefault()
    document.getElementById(opener.dataset.confirmOpen)?.showModal()
    return
  }

  const closer = event.target.closest("[data-confirm-close]")
  if (closer) {
    event.preventDefault()
    closer.closest("dialog")?.close()
  }
})

// The eye on a password field. Flips the field's own type — nothing is copied
// out of it and nothing is stored — and swaps which of the two icons is shown.
// Delegated rather than a hook per field: these fields live on four screens and
// none of them needs to know about this.
window.addEventListener("click", (event) => {
  const toggle = event.target.closest("[data-password-toggle]")
  if (!toggle) return

  event.preventDefault()
  const field = document.getElementById(toggle.dataset.passwordToggle)
  if (!field) return

  const revealing = field.type === "password"
  field.type = revealing ? "text" : "password"
  toggle.querySelector(".password-shown")?.classList.toggle("hidden", revealing)
  toggle.querySelector(".password-hidden")?.classList.toggle("hidden", !revealing)

  const label = revealing ? toggle.dataset.hideLabel : toggle.dataset.showLabel
  if (label) {
    toggle.setAttribute("aria-label", label)
    toggle.setAttribute("title", label)
  }

  // The caret goes back where it was: revealing a password is something you do
  // *while* typing it, and losing the caret means retyping the whole thing.
  const at = field.value.length
  field.focus()
  field.setSelectionRange(at, at)
})

// The fields somebody types a count into, on the three screens that ask for
// one: the receiving conference, the box count and the mission return.
//
// Two habits of a field, both learned from watching the warehouse. Focusing
// selects what is already there, because every one of these arrives holding a
// number the ledger guessed — landing the caret after it turns "80" into "8060"
// when the operator types what they counted. And letters are dropped on the way
// in rather than rejected on submit, because a count typed one-handed while the
// other hand holds the box is not the moment to explain a validation error.
window.addEventListener("focusin", (event) => {
  const field = event.target.closest("input[data-numeric]")
  if (field) field.select()
})

window.addEventListener("input", (event) => {
  const field = event.target.closest("input[data-numeric]")
  if (!field) return

  const cleaned = field.value.replace(/[^\d.,]/g, "")
  if (cleaned === field.value) return

  // Keep the caret where the typing left it rather than jumping to the end.
  const at = field.selectionStart - (field.value.length - cleaned.length)
  field.value = cleaned
  field.setSelectionRange(at, at)
})

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// The progress bar for anything that navigates or submits. In the app's own
// primary rather than the generic blue it shipped with — read at arm's length in
// a warehouse, a bar in a colour the app uses nowhere else reads as a browser
// artifact and gets ignored.
//
// 120ms, not 300ms: on the phone this is used on, most of these waits are
// somewhere between the two, and a delay longer than the wait means the slow
// half of the app looked like it did nothing at all.
const barColor = getComputedStyle(document.documentElement)
  .getPropertyValue("--color-primary")
  .trim() || "#29d"

topbar.config({barColors: {0: barColor}, barThickness: 3, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(120))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

