// Single shared code path for showing a system notification, reached from
// both delivery transports:
//   - the native `push` event (Web Push, browser inactive/backgrounded)
//   - a `message` posted by the page's own JS (WebSocket, browser active)
// Both transports carry the same {event_id, title, body, url} shape, and
// `event_id` (the server's outbox event UUID) is used to deduplicate: if the
// same event arrives through both transports (a real possibility, since the
// server always fans out to every subscription regardless of whether a live
// WebSocket is also connected), only one system notification is shown.

const DEDUPE_TTL_MS = 2 * 60 * 1000
const seenEvents = new Map()

function alreadyShown(eventId) {
  const now = Date.now()

  for (const [id, seenAt] of seenEvents) {
    if (now - seenAt > DEDUPE_TTL_MS) seenEvents.delete(id)
  }

  if (!eventId) return false
  if (seenEvents.has(eventId)) return true

  seenEvents.set(eventId, now)
  return false
}

function showOrbitNotification(payload) {
  const { event_id: eventId, title, body, url } = payload || {}

  if (alreadyShown(eventId)) return Promise.resolve()

  return self.registration.showNotification(title || "Orbit", {
    body: body || "",
    tag: `orbit:${url || "/"}`,
    renotify: true,
    icon: "/favicon.ico",
    badge: "/favicon.ico",
    data: { url: url || "/" },
  })
}

self.addEventListener("push", function (event) {
  let payload = { event_id: null, title: "Orbit", body: "", url: "/" }

  try {
    const data = event.data ? event.data.json() : {}
    payload = {
      event_id: data.event_id || null,
      title: data.title || "Orbit",
      body: data.body || "",
      url: data.url || "/",
    }
  } catch (_error) {
    // Ignore malformed payloads.
  }

  event.waitUntil(showOrbitNotification(payload))
})

self.addEventListener("message", function (event) {
  if (event.data && event.data.type === "orbit-notify") {
    event.waitUntil(showOrbitNotification(event.data.event))
  }
})

self.addEventListener("notificationclick", function (event) {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/"

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (clientList) {
      for (const client of clientList) {
        if ("focus" in client) {
          client.navigate(url)
          return client.focus()
        }
      }

      if (clients.openWindow) {
        return clients.openWindow(url)
      }
    })
  )
})
