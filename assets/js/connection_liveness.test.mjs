// Run with: node --test assets/js/connection_liveness.test.mjs
import {test} from "node:test"
import assert from "node:assert/strict"
import {createLivenessState, shouldProbe, suspectedSuspend} from "./connection_liveness.js"

test("first-ever probe request is always allowed", () => {
  const state = createLivenessState()
  assert.equal(shouldProbe(state, 0), true)
})

test("a burst of signals within the cooldown window collapses to one probe", () => {
  const state = createLivenessState()
  const cooldownMs = 1000

  assert.equal(shouldProbe(state, 0, cooldownMs), true)
  assert.equal(shouldProbe(state, 100, cooldownMs), false)
  assert.equal(shouldProbe(state, 500, cooldownMs), false)
  assert.equal(shouldProbe(state, 999, cooldownMs), false)
})

test("a burst of 20 signals plays exactly one probe, not 20", () => {
  const state = createLivenessState()
  const cooldownMs = 1000

  const results = Array.from({length: 20}, (_, i) => shouldProbe(state, i * 10, cooldownMs))

  assert.equal(results.filter(Boolean).length, 1)
  assert.equal(results[0], true)
})

test("a probe is allowed again once the cooldown window has elapsed", () => {
  const state = createLivenessState()
  const cooldownMs = 1000

  assert.equal(shouldProbe(state, 0, cooldownMs), true)
  assert.equal(shouldProbe(state, 999, cooldownMs), false)
  assert.equal(shouldProbe(state, 1000, cooldownMs), true)
})

test("a tick close to the expected interval is not a suspend", () => {
  assert.equal(suspectedSuspend(15_000, 15_050), false)
  assert.equal(suspectedSuspend(15_000, 20_000), false)
})

test("a tick at or above the multiplier threshold is a suspend", () => {
  assert.equal(suspectedSuspend(15_000, 30_000), true)
  assert.equal(suspectedSuspend(15_000, 45_000), true)
})

test("a custom multiplier overrides the default threshold", () => {
  assert.equal(suspectedSuspend(15_000, 20_000, 1.2), true)
  assert.equal(suspectedSuspend(15_000, 20_000, 3), false)
})
