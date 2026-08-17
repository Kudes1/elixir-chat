self.addEventListener("push", function (event) {
  let payload = { title: "Orbit", body: "", url: "/" }

  try {
    const data = event.data ? event.data.json() : {}
    payload = { title: data.title || "Orbit", body: data.body || "", url: data.url || "/" }
  } catch (_error) {
    // Ignore malformed payloads.
  }

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      tag: `orbit-push:${payload.url}`,
      renotify: true,
      icon: "/favicon.ico",
      badge: "/favicon.ico",
      data: { url: payload.url },
    })
  )
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
