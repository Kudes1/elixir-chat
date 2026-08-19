// Pure NotificationPolicy: decides whether an incoming chat event should stay
// silent, only update the (already-rendered) unread badge, show a toast, or
// play a sound — never called directly from event handlers, only from the
// "phx:notify" listener in app.js, so no code path can play a sound without
// going through this decision table.
//
// No DOM/LiveSocket dependency on purpose: this is what lets it be unit
// tested (see notification_policy.test.mjs) without standing up a WebSocket.
export const DECISIONS = ["silent", "badge", "toast", "sound"]

export const decide = ({
  connectionState = "live",
  own = false,
  muted = false,
  active = false,
  tabVisible = true,
  tabFocused = true,
  priority = "low",
} = {}) => {
  // Catch-up traffic (and anything before the client has resolved a fresh
  // connect) is silent by construction, regardless of what it is.
  if (connectionState !== "live") return "silent"
  if (own) return "silent"
  if (muted) return "silent"

  const alreadySeen = active && tabVisible && tabFocused
  if (alreadySeen) return priority === "high" ? "badge" : "silent"

  const attentive = tabVisible && tabFocused
  if (!attentive) return priority === "high" ? "sound" : "badge"

  return priority === "high" ? "toast" : "badge"
}
