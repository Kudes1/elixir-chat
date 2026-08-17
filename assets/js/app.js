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
    this.hiddenInput = this.el.form?.querySelector("[name='message[client_message_id]']")
    this.draftKey = () => `orbit:message-draft:v1:${this.el.dataset.userId}:${this.el.dataset.channelId}`
    this.storageKey = this.draftKey()
    this.newId = () => {
      if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()

      const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16))
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      const hex = [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("")
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
    }
    this.readDraft = () => {
      try {
        return JSON.parse(sessionStorage.getItem(this.storageKey) || "null")
      } catch (_error) {
        return null
      }
    }
    this.saveDraft = () => {
      if (!this.hiddenInput) return
      sessionStorage.setItem(this.storageKey, JSON.stringify({
        clientMessageId: this.hiddenInput.value,
        body: this.el.value,
      }))
    }
    this.restoreDraft = resetBody => {
      const draft = this.readDraft()
      const id = draft?.clientMessageId || this.hiddenInput?.value || this.newId()
      if (this.hiddenInput) this.hiddenInput.value = id
      if (draft?.body !== undefined) this.el.value = draft.body
      else if (resetBody) this.el.value = ""
      this.saveDraft()
    }
    this.resize = () => {
      this.el.style.height = "auto"
      this.el.style.height = `${Math.min(this.el.scrollHeight, 176)}px`
    }

    this.submitOnEnter = event => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return

      event.preventDefault()
      this.el.form?.requestSubmit()
    }

    this.onInput = () => {
      this.resize()
      this.saveDraft()
    }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.submitOnEnter)
    this.handleEvent("message_sent", ({client_message_id: acknowledgedId}) => {
      const draft = this.readDraft()
      if (!this.hiddenInput || acknowledgedId !== draft?.clientMessageId) return
      this.el.value = ""
      this.hiddenInput.value = this.newId()
      this.saveDraft()
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
    this.restoreDraft()
    this.resize()
  },
  updated() {
    const nextStorageKey = this.draftKey()
    const conversationChanged = nextStorageKey !== this.storageKey
    this.storageKey = nextStorageKey
    this.hiddenInput = this.el.form?.querySelector("[name='message[client_message_id]']")
    this.restoreDraft(conversationChanged)
    this.resize()
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.submitOnEnter)
  },
}

const MessageList = {
  mounted() {
    this.loadingOlderMessages = false
    this.loadingNewerMessages = false
    this.previousScrollHeight = null
    this.lastMarkedMessageId = null
    this.markConversationRead = () => {
      const distanceFromBottom = this.el.scrollHeight - this.el.clientHeight - this.el.scrollTop
      const messageId = this.el.dataset.newestMessageId

      if (document.visibilityState !== "visible" ||
          !document.hasFocus() ||
          this.el.dataset.atLatest !== "true" ||
          distanceFromBottom > 80 ||
          !messageId ||
          messageId === this.lastMarkedMessageId) return

      this.lastMarkedMessageId = messageId
      this.pushEvent("mark_conversation_read", {
        channel_id: this.el.dataset.channelId,
        message_id: messageId,
      }, reply => {
        if (reply?.error) this.lastMarkedMessageId = null
      })
    }
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
      this.markConversationRead()
    }

    this.handleVisibilityChange = () => this.markConversationRead()
    this.handleWindowFocus = () => this.markConversationRead()

    this.el.addEventListener("scroll", this.handleScroll)
    document.addEventListener("visibilitychange", this.handleVisibilityChange)
    window.addEventListener("focus", this.handleWindowFocus)
    this.handleEvent("message_sent", () => {
      this.scrollToLatest("smooth")
    })
    this.handleEvent("scroll_to_latest", () => {
      this.scrollToLatest("auto")
      requestAnimationFrame(() => {
        this.markConversationRead()
      })
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
      requestAnimationFrame(() => {
        this.markConversationRead()
      })
    })
    requestAnimationFrame(() => {
      this.scrollToLatest("auto")
      this.markConversationRead()
    })
  },
  updated() {
    this.loadingOlderMessages = false
    this.loadingNewerMessages = false
    requestAnimationFrame(() => {
      this.markConversationRead()
    })
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
    document.removeEventListener("visibilitychange", this.handleVisibilityChange)
    window.removeEventListener("focus", this.handleWindowFocus)
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

const SidebarResize = {
  mounted() {
    this.storageKey = "orbit:sidebar-width:v1"
    this.defaultWidth = Number(this.el.dataset.sidebarDefaultWidth) || 264
    this.minWidth = Number(this.el.dataset.sidebarMinWidth) || 220
    this.maxWidth = Number(this.el.dataset.sidebarMaxWidth) || 480
    this.pointerId = null
    this.activeResizer = null

    this.normalizedWidth = width => {
      return Math.min(this.maxWidth, Math.max(this.minWidth, Math.round(width)))
    }

    this.viewportMaxWidth = () => {
      return Math.max(this.minWidth, Math.min(this.maxWidth, Math.floor(window.innerWidth / 2)))
    }

    this.clampedWidth = width => {
      return Math.min(this.viewportMaxWidth(), this.normalizedWidth(width))
    }

    this.readWidth = value => {
      try {
        const stored = value === undefined ? localStorage.getItem(this.storageKey) : value
        if (stored === null || stored.trim() === "") return this.defaultWidth

        const width = Number(stored)
        return Number.isFinite(width) ? this.normalizedWidth(width) : this.defaultWidth
      } catch (_error) {
        return this.defaultWidth
      }
    }

    this.saveWidth = () => {
      try {
        localStorage.setItem(this.storageKey, String(this.preferredWidth))
      } catch (_error) {
        // Resizing still works when storage is unavailable.
      }
    }

    this.applyWidth = () => {
      const width = this.clampedWidth(this.preferredWidth)
      const resizer = this.el.querySelector("[data-sidebar-resizer]")

      this.el.style.setProperty("--orbit-sidebar-width", `${width}px`)
      if (this.pointerId !== null) this.el.classList.add("sidebar-resizing")

      if (resizer) {
        resizer.setAttribute("aria-valuemax", String(this.viewportMaxWidth()))
        resizer.setAttribute("aria-valuenow", String(width))
      }
    }

    this.handlePointerDown = event => {
      const resizer = event.target.closest("[data-sidebar-resizer]")
      if (!resizer || !this.el.contains(resizer) || (event.pointerType === "mouse" && event.button !== 0)) return

      event.preventDefault()
      this.pointerId = event.pointerId
      this.activeResizer = resizer
      this.el.classList.add("sidebar-resizing")
      resizer.setPointerCapture(event.pointerId)
    }

    this.handlePointerMove = event => {
      if (event.pointerId !== this.pointerId) return

      event.preventDefault()
      const shellLeft = this.el.getBoundingClientRect().left
      this.preferredWidth = this.clampedWidth(event.clientX - shellLeft)
      this.applyWidth()
    }

    this.finishResize = event => {
      if (event.pointerId !== this.pointerId) return

      if (this.activeResizer?.hasPointerCapture(event.pointerId)) {
        this.activeResizer.releasePointerCapture(event.pointerId)
      }

      this.pointerId = null
      this.activeResizer = null
      this.el.classList.remove("sidebar-resizing")
      this.saveWidth()
    }

    this.handleResize = () => this.applyWidth()
    this.handleStorage = event => {
      if (event.key !== this.storageKey) return
      this.preferredWidth = this.readWidth(event.newValue)
      this.applyWidth()
    }

    this.preferredWidth = this.readWidth()
    this.applyWidth()
    this.el.addEventListener("pointerdown", this.handlePointerDown)
    this.el.addEventListener("pointermove", this.handlePointerMove)
    this.el.addEventListener("pointerup", this.finishResize)
    this.el.addEventListener("pointercancel", this.finishResize)
    window.addEventListener("resize", this.handleResize)
    window.addEventListener("storage", this.handleStorage)
  },
  updated() {
    this.applyWidth()
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.handlePointerDown)
    this.el.removeEventListener("pointermove", this.handlePointerMove)
    this.el.removeEventListener("pointerup", this.finishResize)
    this.el.removeEventListener("pointercancel", this.finishResize)
    window.removeEventListener("resize", this.handleResize)
    window.removeEventListener("storage", this.handleStorage)
    this.el.classList.remove("sidebar-resizing")
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

const MessageEditWindow = {
  mounted() {
    this.scheduleHide()
  },
  updated() {
    this.scheduleHide()
  },
  scheduleHide() {
    if (this.timer) clearTimeout(this.timer)

    const deadline = Number(this.el.dataset.editDeadline)
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

const urlBase64ToUint8Array = base64 => {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4)
  const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(normalized)
  const bytes = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
  return bytes
}

const PushNotifications = {
  mounted() {
    this.optOutKey = "orbit:push-opt-out:v1"
    this.button = this.el.querySelector("[data-notifications-toggle]")
    this.vapidKey = this.el.dataset.vapidPublicKey
    this.enabled = this.el.dataset.pushEnabled === "true"
    this.busy = false

    this.supported = Boolean(this.button) &&
      "serviceWorker" in navigator &&
      "PushManager" in window &&
      "Notification" in window &&
      Boolean(this.vapidKey)

    if (!this.supported) {
      if (this.button) this.button.hidden = true
      return
    }

    this.toggle = event => {
      event.preventDefault()
      this.toggleSubscription()
    }
    this.button.addEventListener("click", this.toggle)
    this.render()

    // this.ready lets a click that lands before registration settles wait for
    // it instead of silently doing nothing; the trailing .catch keeps it from
    // rejecting, so awaiting it later is always safe.
    this.ready = navigator.serviceWorker.register("/sw.js")
      .then(registration => {
        this.registration = registration
        return this.reconcile()
      })
      .catch(error => {
        console.warn("Unable to register the push notification service worker", error)
        this.render()
      })
  },
  updated() {
    // Reflect state changes pushed from the server (another tab unsubscribed,
    // an admin cleared subscriptions, …). Skip while we own an in-flight
    // change so we don't clobber it with a stale server value mid-flight.
    if (!this.supported || this.busy) return
    this.enabled = this.el.dataset.pushEnabled === "true"
    this.render()
  },
  async reconcile() {
    if (!this.registration) return

    try {
      if (Notification.permission === "denied") {
        await this.dropLocalSubscription()
        return
      }

      const subscription = await this.registration.pushManager.getSubscription()

      if (subscription) {
        if (this.optedOut()) {
          await this.unsubscribe(subscription)
          return
        }

        const reply = await this.pushEventWithReply("push_subscribe", {
          subscription: subscription.toJSON(),
        })

        this.enabled = reply?.ok === true
        if (!this.enabled) await subscription.unsubscribe().catch(() => false)
        this.render()
        return
      }

      if (Notification.permission === "granted" && !this.optedOut()) {
        await this.enable()
      } else {
        this.enabled = false
      }

      this.render()
    } catch (error) {
      console.warn("Unable to reconcile the push notification subscription", error)
      this.enabled = false
      this.render()
    }
  },
  async toggleSubscription() {
    // Claim `busy` synchronously, before any `await`, so a second click fired
    // while this one is still in flight (including while still waiting on
    // `this.ready`) always sees it set and bails out instead of racing us.
    if (this.busy) return
    this.busy = true
    this.render()

    try {
      if (!this.registration) await this.ready
      if (!this.registration) return
      if (Notification.permission === "denied") return

      if (this.enabled) await this.disable()
      else await this.enable()
    } catch (error) {
      console.warn("Unable to toggle push notifications", error)
    } finally {
      this.busy = false
      this.render()
    }
  },
  async enable() {
    try {
      const permission = await Notification.requestPermission()
      if (permission !== "granted") {
        this.enabled = false
        return
      }

      let subscription = await this.registration.pushManager.getSubscription()
      if (!subscription) {
        subscription = await this.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(this.vapidKey),
        })
      }

      const reply = await this.pushEventWithReply("push_subscribe", {
        subscription: subscription.toJSON(),
      })

      if (reply?.ok !== true) {
        await subscription.unsubscribe().catch(() => false)
        this.enabled = false
        return
      }

      localStorage.removeItem(this.optOutKey)
      this.enabled = true
    } catch (error) {
      console.warn("Unable to subscribe to push notifications", error)
      this.enabled = false
    }
  },
  disable(existingSubscription) {
    localStorage.setItem(this.optOutKey, "1")
    return this.unsubscribe(existingSubscription)
  },
  async dropLocalSubscription() {
    const subscription = await this.registration.pushManager.getSubscription()
    if (subscription) {
      await this.unsubscribe(subscription)
    } else {
      this.enabled = false
      this.render()
    }
  },
  async unsubscribe(existingSubscription) {
    try {
      const subscription = existingSubscription || await this.registration.pushManager.getSubscription()
      if (!subscription) {
        this.enabled = false
        this.render()
        return
      }

      await subscription.unsubscribe().catch(error => {
        console.warn("Unable to remove the browser push subscription", error)
        return false
      })

      const reply = await this.pushEventWithReply("push_unsubscribe", {
        endpoint: subscription.endpoint,
      })
      if (reply?.ok !== true) console.warn("The server rejected the unsubscribe request")

      this.enabled = false
      this.render()
    } catch (error) {
      console.warn("Unable to unsubscribe from push notifications", error)
      this.enabled = false
      this.render()
    }
  },
  optedOut() {
    try {
      return localStorage.getItem(this.optOutKey) === "1"
    } catch (_error) {
      return false
    }
  },
  pushEventWithReply(event, payload) {
    return new Promise(resolve => this.pushEvent(event, payload, resolve))
  },
  state() {
    if (this.busy) return "pending"
    if (Notification.permission === "denied") return "blocked"
    return this.enabled ? "on" : "off"
  },
  render() {
    if (!this.button) return

    const state = this.state()
    const labels = {
      on: "Отключить уведомления",
      off: "Включить уведомления",
      pending: "Изменение настроек уведомлений…",
      blocked: "Уведомления заблокированы в настройках браузера. Разрешите их для этого сайта, чтобы включить.",
    }

    this.button.dataset.notificationsState = state
    this.button.disabled = state === "pending"
    this.button.setAttribute("aria-busy", String(state === "pending"))
    this.button.setAttribute("aria-pressed", String(state === "on"))
    this.button.setAttribute("aria-label", `Браузерные уведомления: ${labels[state].toLowerCase()}`)
    this.button.title = labels[state]

    const on = this.button.querySelector('[data-notifications-icon="on"]')
    const off = this.button.querySelector('[data-notifications-icon="off"]')
    if (on) on.hidden = state !== "on"
    if (off) off.hidden = state === "on"
  },
  destroyed() {
    this.button?.removeEventListener("click", this.toggle)
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  }),
  hooks: {
    ...colocatedHooks,
    MessageComposer,
    MessageList,
    SidebarSections,
    SidebarResize,
    MessageDeleteWindow,
    MessageEditWindow,
    PushNotifications,
  },
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
