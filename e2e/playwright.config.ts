import {defineConfig} from "@playwright/test"

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  expect: {timeout: 7_000},
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "line",
  use: {
    baseURL: process.env.BASE_URL || "http://127.0.0.1:4000",
    screenshot: {mode: "only-on-failure", fullPage: true},
    trace: "on-first-retry",
  },
  projects: [
    {name: "chromium-desktop", use: {browserName: "chromium", viewport: {width: 1440, height: 900}}},
    {name: "chromium-mobile", use: {browserName: "chromium", viewport: {width: 375, height: 812}, hasTouch: true, isMobile: true}},
  ],
})
