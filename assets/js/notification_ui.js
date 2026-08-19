// DOM-coupled half of the notification feature: playing a sound. Deliberately
// separate from notification_policy.js (which decides *whether* to call this)
// so the decision logic stays unit testable without a DOM. System notification
// display itself lives in the Service Worker (priv/static/sw.js), reached via
// postMessage() — see the "phx:notify" listener in app.js.
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
    // No sound this time; the system notification already carries the information.
  }
}
