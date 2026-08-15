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
import {hooks as colocatedHooks} from "phoenix-colocated/elixir_chat"
import topbar from "../vendor/topbar"

const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
const setTheme = theme => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.setAttribute("data-theme", systemTheme())
    document.documentElement.setAttribute("data-theme-source", "system")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
    document.documentElement.setAttribute("data-theme-source", "user")
  }
}

setTheme(localStorage.getItem("phx:theme") || "system")
window.addEventListener("storage", event => event.key === "phx:theme" && setTheme(event.newValue || "system"))
window.addEventListener("phx:set-theme", event => setTheme(event.target.dataset.phxTheme))
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (document.documentElement.getAttribute("data-theme-source") === "system") setTheme("system")
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const MessageComposer = {
  mounted() {
    this.resize = () => {
      this.el.style.height = "auto"
      this.el.style.height = `${Math.min(this.el.scrollHeight, 176)}px`
    }

    this.submitOnEnter = event => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return

      event.preventDefault()
      this.el.form?.requestSubmit()
    }

    this.el.addEventListener("input", this.resize)
    this.el.addEventListener("keydown", this.submitOnEnter)
    this.handleEvent("message_sent", () => {
      this.el.value = ""
      this.resize()
      this.el.focus()
    })
    this.handleEvent("insert_mention", ({mention}) => {
      const start = this.el.selectionStart ?? this.el.value.length
      const end = this.el.selectionEnd ?? start
      const before = this.el.value.slice(0, start)
      const after = this.el.value.slice(end)
      const leadingSpace = before.length > 0 && !/\s$/.test(before) ? " " : ""
      const trailingSpace = after.length === 0 || !/^\s/.test(after) ? " " : ""
      const inserted = `${leadingSpace}${mention}${trailingSpace}`

      this.el.setRangeText(inserted, start, end, "end")
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
      this.el.focus()
      this.resize()
    })
    this.resize()
  },
  updated() {
    this.resize()
  },
  destroyed() {
    this.el.removeEventListener("input", this.resize)
    this.el.removeEventListener("keydown", this.submitOnEnter)
  },
}

const MessageList = {
  mounted() {
    this.loadingOlderMessages = false
    this.loadingNewerMessages = false
    this.previousScrollHeight = null
    this.scrollToLatest = behavior => {
      this.el.scrollTo({top: this.el.scrollHeight, behavior})
    }
    this.loadOlderMessages = () => {
      if (this.el.dataset.hasOlder !== "true" || this.loadingOlderMessages || this.el.scrollTop > 80) return

      this.loadingOlderMessages = true
      this.previousScrollHeight = this.el.scrollHeight
      this.pushEvent("load_older_messages", {})
    }

    this.loadNewerMessages = () => {
      const distanceFromBottom = this.el.scrollHeight - this.el.clientHeight - this.el.scrollTop
      if (this.el.dataset.hasNewer !== "true" || this.loadingNewerMessages || distanceFromBottom > 80) return

      this.loadingNewerMessages = true
      this.pushEvent("load_newer_messages", {})
    }

    this.handleScroll = () => {
      this.loadOlderMessages()
      this.loadNewerMessages()
    }

    this.el.addEventListener("scroll", this.handleScroll)
    this.handleEvent("message_sent", () => {
      this.scrollToLatest("smooth")
    })
    this.handleEvent("scroll_to_latest", () => {
      this.scrollToLatest("auto")
    })
    this.handleEvent("older_messages_loaded", () => {
      if (this.previousScrollHeight !== null) {
        this.el.scrollTop += this.el.scrollHeight - this.previousScrollHeight
      }

      this.previousScrollHeight = null
      this.loadingOlderMessages = false
    })
    this.handleEvent("newer_messages_loaded", () => {
      this.loadingNewerMessages = false
    })
    requestAnimationFrame(() => this.scrollToLatest("auto"))
  },
  updated() {
    this.loadingOlderMessages = false
    this.loadingNewerMessages = false
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
  },
}

const SidebarSections = {
  mounted() {
    this.storageKey = "orbit:sidebar-sections:v1"
    this.sectionState = {channels: true, directs: true}

    this.readState = value => {
      try {
        const stored = JSON.parse(value ?? localStorage.getItem(this.storageKey) ?? "{}")
        this.sectionState = {
          channels: stored.channels !== false,
          directs: stored.directs !== false,
        }
      } catch (_error) {
        this.sectionState = {channels: true, directs: true}
      }
    }

    this.applyState = () => {
      for (const [section, expanded] of Object.entries(this.sectionState)) {
        const toggle = this.el.querySelector(`[data-sidebar-toggle="${section}"]`)
        const content = this.el.querySelector(`[data-sidebar-content="${section}"]`)

        if (toggle) toggle.setAttribute("aria-expanded", String(expanded))
        if (content) content.hidden = !expanded
      }

      this.el.classList.remove("sidebar-sections-pending")
    }

    this.saveState = () => {
      try {
        localStorage.setItem(this.storageKey, JSON.stringify(this.sectionState))
      } catch (_error) {
        // The sidebar still works when storage is unavailable.
      }
    }

    this.handleClick = event => {
      const toggle = event.target.closest("[data-sidebar-toggle]")

      if (toggle && this.el.contains(toggle)) {
        const section = toggle.dataset.sidebarToggle
        this.sectionState[section] = !this.sectionState[section]
        this.applyState()
        this.saveState()
        return
      }

      const openDirectSearch = event.target.closest("[data-open-direct-search]")

      if (openDirectSearch && this.el.contains(openDirectSearch)) {
        this.sectionState.directs = true
        this.applyState()
        this.saveState()
      }
    }

    this.handleStorage = event => {
      if (event.key !== this.storageKey) return
      this.readState(event.newValue)
      this.applyState()
    }

    this.readState()
    this.applyState()
    this.el.addEventListener("click", this.handleClick)
    window.addEventListener("storage", this.handleStorage)
  },
  updated() {
    this.applyState()
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    window.removeEventListener("storage", this.handleStorage)
  },
}

const MessageDeleteWindow = {
  mounted() {
    this.scheduleHide()
  },
  updated() {
    this.scheduleHide()
  },
  scheduleHide() {
    if (this.timer) clearTimeout(this.timer)

    const deadline = Number(this.el.dataset.deleteDeadline)
    if (!deadline) return

    const remaining = deadline - Date.now()
    if (remaining <= 0) {
      this.el.remove()
    } else {
      this.timer = setTimeout(() => this.el.remove(), remaining)
    }
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, MessageComposer, MessageList, SidebarSections, MessageDeleteWindow},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
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
