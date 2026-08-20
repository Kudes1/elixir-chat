import {expect, test, type Page} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"

const password = "orbit-password-123"

async function login(page: Page, login = "orbit-user") {
  await page.goto("/login")
  await page.locator("#login").fill(login)
  await page.locator("#password").fill(password)
  await page.locator("#login-submit").click()
  await expect(page.locator("#chat-shell")).toBeVisible()
}

async function assertAxe(page: Page) {
  await page.waitForTimeout(200)
  const results = await new AxeBuilder({page}).analyze()
  expect(results.violations).toEqual([])
}

test("login and chat pass axe in both themes", async ({page}, testInfo) => {
  await page.goto("/login")
  for (const theme of ["light", "dark"]) {
    await page.locator(`[data-phx-theme="${theme}"]`).click()
    await assertAxe(page)
  }
  await login(page)
  if (testInfo.project.name === "chromium-mobile") await page.locator("#sidebar-toggle").click()
  const profile = page.locator("#open-user-settings")
  await profile.click()
  await expect(page.locator("#user-settings")).toBeVisible()
  for (const theme of ["light", "dark"]) {
    await page.locator(`#settings-theme-switcher [data-phx-theme="${theme}"]`).click()
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme)
    await assertAxe(page)
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  await page.keyboard.press("Escape")
  await expect(page.locator("#user-settings")).not.toBeVisible()
  await expect(profile).toBeFocused()
})

test("theme persists and system follows media", async ({page}) => {
  await page.goto("/login")
  await page.locator('[data-phx-theme="dark"]').click()
  await page.reload()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
  await page.emulateMedia({colorScheme: "light"})
  await page.locator('[data-phx-theme="system"]').click()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light")
  await page.emulateMedia({colorScheme: "dark"})
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")
})

test("saved theme applies before first paint", async ({page}) => {
  await page.addInitScript(() => {
    localStorage.setItem("phx:theme", "dark")

    new PerformanceObserver(entries => {
      if (entries.getEntries().some(entry => entry.name === "first-contentful-paint")) {
        document.documentElement.setAttribute("data-first-paint-theme", document.documentElement.dataset.theme || "")
      }
    }).observe({type: "paint", buffered: true})
  })

  await page.route("**/assets/js/app.js", async route => {
    await new Promise(resolve => setTimeout(resolve, 250))
    await route.continue()
  })
  await page.goto("/login")

  await expect(page.locator("html")).toHaveAttribute("data-first-paint-theme", "dark")
})

test("messages wait for the browser time zone before becoming visible", async ({page}) => {
  await login(page)
  await page.route("**/assets/js/app.js", async route => {
    await new Promise(resolve => setTimeout(resolve, 500))
    await route.continue()
  })
  await page.reload({waitUntil: "commit"})

  const messageList = page.locator("[id^='message-list-']")
  await expect(messageList).toBeHidden()
  await expect(messageList).toBeVisible()
})

test("admin list scrolls and remains inside narrow viewport", async ({page}) => {
  await login(page, "admin")
  await page.goto("/admin/users")
  if (page.url().includes("reauth")) {
    await page.locator("#sudo-password").fill(password)
    await page.locator("#sudo-submit").click()
  }
  await expect(page.locator("#users")).toBeVisible()
  await assertAxe(page)
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  expect(overflow).toBe(false)
  await page.locator("#users > div").last().scrollIntoViewIfNeeded()
})

test("mobile sidebar is inert and restores focus after Escape and backdrop", async ({page}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium-mobile")
  await login(page)
  const toggle = page.locator("#sidebar-toggle")
  const sidebar = page.locator("#chat-sidebar")
  await expect(sidebar).toHaveAttribute("inert", "")
  await toggle.click()
  await expect(sidebar).not.toHaveAttribute("inert", "")
  await page.keyboard.press("Escape")
  await expect(toggle).toBeFocused()
  await toggle.click()
  await expect(page.locator("#chat-shell")).toHaveClass(/sidebar-open/)
  await expect(page.locator("#sidebar-overlay")).toBeVisible()
  await page.locator("#sidebar-overlay").click({position: {x: 370, y: 400}})
  await expect(toggle).toBeFocused()
})

test("resizer supports keyboard", async ({page}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium-desktop")
  await login(page)
  const resizer = page.locator("#sidebar-resizer")
  await expect(resizer).toHaveAttribute("data-keyboard-ready", "true")
  const initial = Number(await resizer.getAttribute("aria-valuenow"))
  await resizer.focus()
  await page.keyboard.press("ArrowRight")
  await expect(resizer).toHaveAttribute("aria-valuenow", String(initial + 8))
  await page.keyboard.press("Home")
  await expect(resizer).toHaveAttribute("aria-valuenow", "220")
})

test("channel dialogs trap and restore focus", async ({page}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium-desktop")
  await login(page)
  for (const [trigger, dialog] of [["#open-channel-create", "#channel-create"], ["#open-channel-catalog", "#channel-catalog"], ["#open-channel-members", "#channel-members-modal"], ["#open-channel-settings", "#channel-settings"]]) {
    await page.locator(trigger).click()
    await expect(page.locator(dialog)).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(page.locator(trigger)).toBeFocused()
  }
})

test("touch message controls are visible and at least 44px", async ({page}, testInfo) => {
  test.skip(testInfo.project.name !== "chromium-mobile")
  await login(page)
  const control = page.locator(".message-menu-toggle").first()
  await expect(control).toBeVisible()
  const box = await control.boundingBox()
  expect(box?.width).toBeGreaterThanOrEqual(44)
  expect(box?.height).toBeGreaterThanOrEqual(44)
})

test("reduced motion removes optional movement and landscape has no overflow", async ({page}) => {
  await page.emulateMedia({reducedMotion: "reduce"})
  await login(page)
  const duration = await page.locator(".chat-sidebar").evaluate(element => parseFloat(getComputedStyle(element).transitionDuration) * 1000)
  expect(duration).toBeLessThanOrEqual(0.02)
  await page.setViewportSize({width: 667, height: 375})
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})
