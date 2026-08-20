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
import {decide as decideNotification} from "./notification_policy"
import {playNotificationSound} from "./notification_ui"
import {createCooldownState, shouldPlaySound} from "./sound_cooldown"
import {
  createLivenessState,
  shouldProbe,
  suspectedSuspend,
  PING_TIMEOUT_MS,
  SUSPEND_TICK_MS,
} from "./connection_liveness"

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

  document.querySelectorAll("[data-phx-theme]").forEach(button => {
    button.setAttribute("aria-pressed", String(button.dataset.phxTheme === theme))
  })
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
    this.mobileQuery = matchMedia("(max-width: 720px)")
    this.sidebar = this.el.querySelector("#chat-sidebar")

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
    this.syncSidebarA11y = () => {
      if (!this.sidebar) return
      const closedMobile = this.mobileQuery.matches && !this.sidebar.classList.contains("sidebar-open")
      this.sidebar.toggleAttribute("inert", closedMobile)
      if (closedMobile) this.sidebar.setAttribute("aria-hidden", "true")
      else this.sidebar.removeAttribute("aria-hidden")
    }
    this.handleMediaChange = () => this.syncSidebarA11y()
    this.sidebarObserver = new MutationObserver(() => this.syncSidebarA11y())
    this.handleStorage = event => {
      if (event.key !== this.storageKey) return
      this.preferredWidth = this.readWidth(event.newValue)
      this.applyWidth()
    }

    this.preferredWidth = this.readWidth()
    this.applyWidth()
    this.syncSidebarA11y()
    if (this.sidebar) this.sidebarObserver.observe(this.sidebar, {attributes: true, attributeFilter: ["class"]})
    this.el.addEventListener("pointerdown", this.handlePointerDown)
    this.el.addEventListener("pointermove", this.handlePointerMove)
    this.el.addEventListener("pointerup", this.finishResize)
    this.el.addEventListener("pointercancel", this.finishResize)
    window.addEventListener("resize", this.handleResize)
    window.addEventListener("storage", this.handleStorage)
    this.mobileQuery.addEventListener("change", this.handleMediaChange)
  },
  updated() {
    this.applyWidth()
    this.syncSidebarA11y()
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.handlePointerDown)
    this.el.removeEventListener("pointermove", this.handlePointerMove)
    this.el.removeEventListener("pointerup", this.finishResize)
    this.el.removeEventListener("pointercancel", this.finishResize)
    window.removeEventListener("resize", this.handleResize)
    window.removeEventListener("storage", this.handleStorage)
    this.mobileQuery.removeEventListener("change", this.handleMediaChange)
    this.sidebarObserver.disconnect()
    this.el.classList.remove("sidebar-resizing")
  },
}

const SidebarResizerKeyboard = {
  mounted() {
    this.handleKeydown = event => {
      const min = Number(this.el.getAttribute("aria-valuemin"))
      const max = Number(this.el.getAttribute("aria-valuemax"))
      const current = Number(this.el.getAttribute("aria-valuenow"))
      let width
      if (event.key === "ArrowLeft") width = current - 8
      else if (event.key === "ArrowRight") width = current + 8
      else if (event.key === "Home") width = min
      else if (event.key === "End") width = max
      else return
      event.preventDefault()
      width = Math.min(max, Math.max(min, width))
      this.el.closest("#chat-shell")?.style.setProperty("--orbit-sidebar-width", `${width}px`)
      this.el.setAttribute("aria-valuenow", String(width))
      localStorage.setItem("orbit:sidebar-width:v1", String(width))
    }
    this.el.addEventListener("keydown", this.handleKeydown)
    this.el.dataset.keyboardReady = "true"
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.handleKeydown)
    delete this.el.dataset.keyboardReady
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
    this.button = null
    this.vapidKey = this.el.dataset.vapidPublicKey
    this.enabled = this.el.dataset.pushEnabled === "true"
    this.busy = false

    this.supported = this.el.dataset.pushAvailable === "true" &&
      "serviceWorker" in navigator &&
      "PushManager" in window &&
      "Notification" in window &&
      Boolean(this.vapidKey)

    this.toggle = event => {
      event.preventDefault()
      this.toggleSubscription()
    }
    this.connectButton()

    // this.ready lets a click that lands before registration settles wait for
    // it instead of silently doing nothing; the trailing .catch keeps it from
    // rejecting, so awaiting it later is always safe.
    this.ready = this.supported
      ? navigator.serviceWorker.register("/sw.js")
        .then(registration => {
          this.registration = registration
          return this.reconcile()
        })
        .catch(error => {
          console.warn("Unable to register the push notification service worker", error)
          this.render()
        })
      : Promise.resolve()
  },
  updated() {
    // Reflect state changes pushed from the server (another tab unsubscribed,
    // an admin cleared subscriptions, …). Skip while we own an in-flight
    // change so we don't clobber it with a stale server value mid-flight.
    if (!this.busy) this.enabled = this.el.dataset.pushEnabled === "true"
    this.connectButton()
  },
  connectButton() {
    const button = this.el.querySelector("[data-notifications-toggle]")
    if (button === this.button) {
      this.render()
      return
    }

    this.button?.removeEventListener("click", this.toggle)
    this.button = button
    this.button?.addEventListener("click", this.toggle)
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
    if (!this.supported) return "unavailable"
    if (this.busy) return "pending"
    if (Notification.permission === "denied") return "blocked"
    return this.enabled ? "on" : "off"
  },
  render() {
    if (!this.button) return

    const state = this.state()
    const labels = {
      on: "Включены",
      off: "Выключены",
      pending: "Сохраняем…",
      blocked: "Заблокированы",
      unavailable: "Недоступны",
    }

    this.button.dataset.notificationsState = state
    this.button.disabled = ["pending", "blocked", "unavailable"].includes(state)
    this.button.setAttribute("aria-busy", String(state === "pending"))
    this.button.setAttribute("aria-pressed", String(state === "on"))
    this.button.setAttribute("aria-label", `Браузерные уведомления: ${labels[state]}`)
    this.button.title = state === "on" ? "Отключить уведомления" : state === "off" ? "Включить уведомления" : labels[state]
    const status = this.button.querySelector("[data-notifications-status]")
    if (status) status.textContent = labels[state]

    const on = this.button.querySelector('[data-notifications-icon="on"]')
    const off = this.button.querySelector('[data-notifications-icon="off"]')
    if (on) on.hidden = state !== "on"
    if (off) off.hidden = state === "on"
  },
  destroyed() {
    this.button?.removeEventListener("click", this.toggle)
  },
}

// Whether to play the notification sound at all — purely a browser/device
// preference (localStorage), independent of the toast/system-notification
// decision made by notification_policy.js. Read once at load, then kept in
// sync both from this tab's own toggle clicks and from a `storage` event
// fired by another tab toggling the same preference.
const NOTIFICATION_SOUND_STORAGE_KEY = "orbit:notification-sound:v1"

const readNotificationSoundEnabled = () => {
  try {
    return localStorage.getItem(NOTIFICATION_SOUND_STORAGE_KEY) !== "off"
  } catch (_error) {
    return true
  }
}

const notificationSoundState = {
  enabled: readNotificationSoundEnabled(),
  listeners: [],
  onChange(listener) {
    this.listeners.push(listener)
  },
  offChange(listener) {
    const index = this.listeners.indexOf(listener)
    if (index !== -1) this.listeners.splice(index, 1)
  },
  set(enabled) {
    this.enabled = enabled
    try {
      localStorage.setItem(NOTIFICATION_SOUND_STORAGE_KEY, enabled ? "on" : "off")
    } catch (_error) {
      // The preference just won't persist across reloads when storage is unavailable.
    }
    this.listeners.forEach(listener => listener(enabled))
  },
}

window.addEventListener("storage", event => {
  if (event.key !== NOTIFICATION_SOUND_STORAGE_KEY) return
  notificationSoundState.enabled = event.newValue !== "off"
  notificationSoundState.listeners.forEach(listener => listener(notificationSoundState.enabled))
})

const NotificationSound = {
  mounted() {
    this.render = enabled => {
      const state = enabled ?? notificationSoundState.enabled
      this.el.dataset.soundState = state ? "on" : "off"
      this.el.setAttribute("aria-pressed", String(state))
      this.el.setAttribute("aria-label", `Звук уведомлений: ${state ? "включён" : "отключён"}`)
      this.el.title = state ? "Отключить звук уведомлений" : "Включить звук уведомлений"
      const status = this.el.querySelector("[data-notification-sound-status]")
      if (status) status.textContent = state ? "Включён" : "Выключен"

      const on = this.el.querySelector('[data-notification-sound-icon="on"]')
      const off = this.el.querySelector('[data-notification-sound-icon="off"]')
      if (on) on.hidden = !state
      if (off) off.hidden = state
    }
    this.toggle = event => {
      event.preventDefault()
      notificationSoundState.set(!notificationSoundState.enabled)
    }

    notificationSoundState.onChange(this.render)
    this.el.addEventListener("click", this.toggle)
    this.render()
  },
  updated() {
    // The button's on/off markup is static in the template (this preference
    // has no server-side assign backing it), so any LiveView patch touching
    // this region — e.g. the sidebar re-rendering for an unread-count bump —
    // morphs it back to the default "on" HTML. Re-apply our actual state.
    this.render()
  },
  destroyed() {
    this.el.removeEventListener("click", this.toggle)
    notificationSoundState.offChange(this.render)
  },
}

// Per-partition ("channel:<id>") resume cursors: the highest outbox event
// sequence this browser has already applied. Sent back on every connect/
// reconnect so the server can replay only what was missed. Advanced live via
// the "event_seq" server-pushed event (see ElixirChatWeb.ChatLive's
// handle_info({:event_sequence, ...})) so it stays current between visits,
// not just at catch-up time.
const EVENT_SEQ_STORAGE_KEY = "orbit:event-seq:v1"

const readEventSequenceCursors = () => {
  try {
    const parsed = JSON.parse(localStorage.getItem(EVENT_SEQ_STORAGE_KEY))
    return (parsed && typeof parsed === "object") ? parsed : {}
  } catch {
    return {}
  }
}

const writeEventSequenceCursors = cursors => {
  try {
    localStorage.setItem(EVENT_SEQ_STORAGE_KEY, JSON.stringify(cursors))
  } catch {
    // localStorage unavailable (private mode/quota) - cursors just won't persist
  }
}

window.addEventListener("phx:event_seq", ({detail}) => {
  const partitionKey = detail?.partition_key
  const seq = detail?.seq
  if (!partitionKey || typeof seq !== "number") return

  const cursors = readEventSequenceCursors()
  if (!(cursors[partitionKey] >= seq)) {
    cursors[partitionKey] = seq
    writeEventSequenceCursors(cursors)
  }
})

// Client connection state machine: DISCONNECTED -> CONNECTING -> (CATCHING_UP
// | LIVE). Mirrors ElixirChatWeb.ChatLive.ConnectionState.transition/2 (lib/
// elixir_chat_web/live/chat_live/connection_state.ex), which is the source of
// truth for which transitions are valid — keep both tables in sync. "connect"/
// "disconnect" are only observable client-side (the browser knows about the
// socket before the server does); whether a connect resolves to CATCHING_UP or
// LIVE always comes from the server via #connection-state's data attributes,
// computed by the same Elixir module.
const CONNECTION_TRANSITIONS = {
  "disconnected:connect": "connecting",
  "connecting:connected_live": "live",
  "connecting:connected_catching_up": "catching_up",
  "connecting:disconnect": "disconnected",
  "catching_up:caught_up": "live",
  "catching_up:disconnect": "disconnected",
  "live:disconnect": "disconnected",
  "disconnected:disconnect": "disconnected",
}

const connectionState = {
  current: "disconnected",
  listeners: [],
  onChange(listener) {
    this.listeners.push(listener)
  },
  send(event) {
    const next = CONNECTION_TRANSITIONS[`${this.current}:${event}`]
    if (!next) {
      console.warn(`[connection-state] ignored invalid transition "${event}" from "${this.current}"`)
      return this.current
    }
    if (next !== this.current) {
      this.current = next
      this.listeners.forEach(listener => listener(next))
    }
    return next
  },
}

// Resolves CONNECTING once a (re)connect completes, using the freshly rendered
// #connection-state data attributes (computed server-side by ConnectionState.
// initial_state/1) to decide whether we land in CATCHING_UP or LIVE.
const resolveConnected = hook => {
  const el = document.getElementById("connection-state")
  const catchingUp = el?.dataset.catchingUp === "true"
  const resolved = connectionState.send(catchingUp ? "connected_catching_up" : "connected_live")

  if (resolved === "catching_up") {
    // Nothing async to wait for yet — the backlog is already reflected in the
    // freshly rendered state, not replayed event-by-event. Tell the server too
    // (ChatLive's `client_caught_up` handle_event), since `@connection_state`
    // otherwise never advances past :catching_up for the life of this connected
    // process — and NotificationPolicy's server-side "only push while live"
    // gate depends on that assign being current.
    queueMicrotask(() => {
      connectionState.send("caught_up")
      hook.pushEvent("client_caught_up", {})
    })
  }
}

const ConnectionState = {
  mounted() {
    resolveConnected(this)

    // tasks/connect_concept.txt item 2/3: an open WebSocket alone is not
    // proof of readiness. On any of these lifecycle signals, if we currently
    // *believe* we're live, actively verify with a server round trip instead
    // of waiting for Phoenix's own ~30s heartbeat timeout to notice.
    this.livenessState = createLivenessState()
    this.probeInFlight = false
    this.lastSuspendTick = Date.now()

    this.verifyLiveness = reason => {
      if (connectionState.current !== "live") return // reconnect/catch-up already owns this path
      if (this.probeInFlight) return
      if (!shouldProbe(this.livenessState, Date.now())) return
      this.probe(reason)
    }

    this.probe = reason => {
      this.probeInFlight = true
      let settled = false

      const timer = setTimeout(() => {
        if (settled) return
        settled = true
        this.probeInFlight = false
        console.warn(`[connection-liveness] "${reason}" ping timed out — forcing reconnect`)
        liveSocket.disconnect(() => liveSocket.connect())
      }, PING_TIMEOUT_MS)

      this.pushEvent("ping", {}, () => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        this.probeInFlight = false
      })
    }

    this.onOnline = () => this.verifyLiveness("online")
    this.onOffline = () => this.verifyLiveness("offline")
    this.onVisibilityChange = () => this.verifyLiveness("visibilitychange")
    this.onFocus = () => this.verifyLiveness("focus")
    this.onPageShow = () => this.verifyLiveness("pageshow")

    window.addEventListener("online", this.onOnline)
    window.addEventListener("offline", this.onOffline)
    document.addEventListener("visibilitychange", this.onVisibilityChange)
    window.addEventListener("focus", this.onFocus)
    window.addEventListener("pageshow", this.onPageShow)

    // Device-sleep/tab-suspend heuristic: no native browser event exists for
    // this, so a recurring timer whose actual gap is much larger than
    // scheduled implies the tab/OS was suspended in between ticks.
    this.suspendTimer = setInterval(() => {
      const now = Date.now()
      const elapsed = now - this.lastSuspendTick
      this.lastSuspendTick = now
      if (suspectedSuspend(SUSPEND_TICK_MS, elapsed)) this.verifyLiveness("resume")
    }, SUSPEND_TICK_MS)
  },
  reconnected() {
    resolveConnected(this)
  },
  disconnected() {
    connectionState.send("disconnect")
    // Phoenix's LiveSocket retries automatically, so we're immediately back to
    // attempting a connection rather than sitting idle.
    connectionState.send("connect")
  },
  destroyed() {
    window.removeEventListener("online", this.onOnline)
    window.removeEventListener("offline", this.onOffline)
    document.removeEventListener("visibilitychange", this.onVisibilityChange)
    window.removeEventListener("focus", this.onFocus)
    window.removeEventListener("pageshow", this.onPageShow)
    clearInterval(this.suspendTimer)
  },
}

// NotificationPolicy wiring: ChatLive pushes "notify" only for events the
// server already knows can't be silent-by-construction catch-up traffic, the
// author's own message, or a muted conversation (see `maybe_notify_*` in
// chat_live.ex). Everything genuinely client-only — current connection state,
// tab visibility/focus — is supplied here, right before the decision is made.
// `priority` itself also comes from the server (a DM, or a channel message
// that actually `@mention`-ed this recipient, is "high"; an ordinary channel
// message is "low") — only the server can tell mention from non-mention.
//
// Sound-spam protection (tasks/05-sound-spam-protection.md): several "sound"
// decisions in a row for the *same conversation* (e.g. a burst of DMs from
// one person while the tab is unfocused) must not become a burst of beeps.
// `soundCooldownState` groups by `channel_id` — the same identifier the
// server already resolves for both channel and direct messages — so the
// system notification still fires for every event (data isn't suppressed,
// only the sound), while `shouldPlaySound` throttles the sound itself,
// independently per conversation, per the single config in sound_cooldown.js.
const soundCooldownState = createCooldownState()

// Forwards a WebSocket-delivered event to the Service Worker so it goes
// through the exact same showNotification() code path as a Web Push delivery
// of the same event (see priv/static/sw.js) — the SW dedupes by `event_id`
// in case both transports end up delivering it. Requires Notification
// permission (granted only via the PushNotifications hook's opt-in), so a
// user who never enabled push simply gets no system notification here.
const notifySystem = event => {
  if (!("serviceWorker" in navigator) || !("Notification" in window)) return
  if (Notification.permission !== "granted") return

  navigator.serviceWorker.ready
    .then(registration => registration.active?.postMessage({type: "orbit-notify", event}))
    .catch(() => {})
}

window.addEventListener("phx:notify", ({detail}) => {
  const priority = detail?.priority === "high" ? "high" : "low"
  const decision = decideNotification({
    connectionState: connectionState.current,
    active: Boolean(detail?.active),
    tabVisible: document.visibilityState === "visible",
    tabFocused: document.hasFocus(),
    priority,
  })

  if (decision === "toast" || decision === "sound") {
    notifySystem({
      event_id: detail?.event_id,
      title: detail?.title,
      body: detail?.body,
      url: detail?.url,
    })
  }
  if (decision === "sound" && notificationSoundState.enabled &&
      shouldPlaySound(soundCooldownState, detail?.channel_id, priority, Date.now())) {
    playNotificationSound()
  }
})

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    last_sequences: readEventSequenceCursors(),
  }),
  hooks: {
    ...colocatedHooks,
    MessageComposer,
    MessageList,
    SidebarSections,
    SidebarResize,
    SidebarResizerKeyboard,
    MessageDeleteWindow,
    MessageEditWindow,
    PushNotifications,
    NotificationSound,
    ConnectionState,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
connectionState.send("connect")
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// expose the connection state machine for debugging and for later iterations
// (NotificationPolicy) to read `window.orbitConnectionState.current`:
// >> orbitConnectionState.current
window.orbitConnectionState = connectionState

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
