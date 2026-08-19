// Run with: node --test assets/js/notification_policy.test.mjs
// (Node's built-in test runner — no extra JS test infra to add for one pure
// function; see tasks/02-client-state-machine.md for why this project still
// has no npm/jest/vitest setup.)
import {test} from "node:test"
import assert from "node:assert/strict"
import {decide} from "./notification_policy.js"

const base = {
  connectionState: "live",
  own: false,
  muted: false,
  active: false,
  tabVisible: true,
  tabFocused: true,
  priority: "low",
}

test("catching up + any event -> silent", () => {
  assert.equal(decide({...base, connectionState: "catching_up", priority: "high"}), "silent")
  assert.equal(decide({...base, connectionState: "catching_up", priority: "low"}), "silent")
})

test("connecting/disconnected + any event -> silent", () => {
  assert.equal(decide({...base, connectionState: "connecting"}), "silent")
  assert.equal(decide({...base, connectionState: "disconnected"}), "silent")
})

test("live + own message -> silent", () => {
  assert.equal(decide({...base, own: true, priority: "high"}), "silent")
})

test("live + muted conversation -> silent", () => {
  assert.equal(decide({...base, muted: true, priority: "high"}), "silent")
})

test("live + ordinary channel message, tab attentive, conversation not open -> low-intrusion badge", () => {
  assert.equal(decide({...base, priority: "low"}), "badge")
})

test("live + direct message, tab attentive, conversation not open -> toast", () => {
  assert.equal(decide({...base, priority: "high"}), "toast")
})

test("live + direct message, tab hidden/unfocused -> sound", () => {
  assert.equal(decide({...base, priority: "high", tabVisible: false}), "sound")
  assert.equal(decide({...base, priority: "high", tabFocused: false}), "sound")
})

test("live + active conversation open and focused -> suppressed (reduced)", () => {
  assert.equal(decide({...base, priority: "high", active: true}), "badge")
  assert.equal(decide({...base, priority: "low", active: true}), "silent")
})

test("active conversation open but tab not focused still escalates", () => {
  assert.equal(decide({...base, priority: "high", active: true, tabFocused: false}), "sound")
})
