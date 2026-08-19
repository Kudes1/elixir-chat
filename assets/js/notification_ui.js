// DOM-coupled half of the notification feature: rendering a toast and
// playing a sound. Deliberately separate from notification_policy.js (which
// decides *whether* to call these) so the decision logic stays unit
// testable without a DOM.
const MAX_VISIBLE_TOASTS = 3
const TOAST_LIFETIME_MS = 5000

let toastContainer = null

const ensureContainer = () => {
  if (toastContainer && document.body.contains(toastContainer)) return toastContainer

  toastContainer = document.createElement("div")
  toastContainer.id = "orbit-toast-container"
  toastContainer.setAttribute("role", "status")
  toastContainer.setAttribute("aria-live", "polite")
  document.body.appendChild(toastContainer)
  return toastContainer
}

export const showToast = ({title, senderName, senderLogin, preview}) => {
  const container = ensureContainer()

  while (container.children.length >= MAX_VISIBLE_TOASTS) {
    container.firstElementChild?.remove()
  }

  const toast = document.createElement("div")
  toast.className = "orbit-toast"

  // `title` only carries the channel name ("#general") — for direct messages
  // it's absent, since the sender name below already says who it's from.
  const children = []
  if (title) {
    const titleEl = document.createElement("strong")
    titleEl.className = "orbit-toast-title"
    titleEl.textContent = title
    children.push(titleEl)
  }

  const senderEl = document.createElement("span")
  senderEl.className = "orbit-toast-sender"

  const senderNameEl = document.createElement("strong")
  senderNameEl.textContent = senderName || ""
  senderEl.append(senderNameEl)

  if (senderLogin) {
    const loginEl = document.createElement("span")
    loginEl.className = "orbit-toast-login"
    loginEl.textContent = `@${senderLogin}`
    senderEl.append(" ", loginEl)
  }

  children.push(senderEl)

  const previewEl = document.createElement("p")
  previewEl.className = "orbit-toast-preview"
  previewEl.textContent = preview || ""
  children.push(previewEl)

  toast.append(...children)
  container.appendChild(toast)
  requestAnimationFrame(() => toast.classList.add("orbit-toast-visible"))

  const dismiss = () => {
    toast.classList.remove("orbit-toast-visible")
    toast.addEventListener("transitionend", () => toast.remove(), {once: true})
  }

  toast.addEventListener("click", dismiss)
  setTimeout(dismiss, TOAST_LIFETIME_MS)
}

let audioContext = null

// A short synthesized beep rather than a bundled audio asset — one less
// binary file to ship, and it's trivial to tweak. Best-effort: notification
// sound failing (autoplay policy, no Web Audio support, …) must never break
// message handling.
export const playNotificationSound = () => {
  try {
    if (!audioContext) audioContext = new (window.AudioContext || window.webkitAudioContext)()
    if (audioContext.state === "suspended") audioContext.resume().catch(() => {})

    const now = audioContext.currentTime
    const oscillator = audioContext.createOscillator()
    const gain = audioContext.createGain()

    oscillator.type = "sine"
    oscillator.frequency.setValueAtTime(880, now)
    gain.gain.setValueAtTime(0.0001, now)
    gain.gain.exponentialRampToValueAtTime(0.2, now + 0.01)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.25)

    oscillator.connect(gain)
    gain.connect(audioContext.destination)
    oscillator.start(now)
    oscillator.stop(now + 0.26)
  } catch (_error) {
    // No sound this time; the toast/badge already carry the information.
  }
}
