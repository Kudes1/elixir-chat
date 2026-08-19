// Run with: node --test assets/js/sound_cooldown.test.mjs
import {test} from "node:test"
import assert from "node:assert/strict"
import {createCooldownState, shouldPlaySound, DEFAULT_COOLDOWN_MS} from "./sound_cooldown.js"

test("first sound for a conversation always plays", () => {
  const state = createCooldownState()
  assert.equal(shouldPlaySound(state, "channel:1", "high", 0), true)
})

test("a burst of events in the same conversation within the cooldown window collapses to one sound", () => {
  const state = createCooldownState()
  const cooldownMs = {high: 1000, low: 1000}

  assert.equal(shouldPlaySound(state, "channel:1", "high", 0, cooldownMs), true)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 100, cooldownMs), false)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 500, cooldownMs), false)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 999, cooldownMs), false)
})

test("a burst of 20 LIVE events in the same conversation plays exactly one sound, not 20", () => {
  const state = createCooldownState()
  const cooldownMs = {high: 1000, low: 1000}

  const results = Array.from({length: 20}, (_, i) =>
    shouldPlaySound(state, "channel:1", "high", i * 10, cooldownMs)
  )

  assert.equal(results.filter(Boolean).length, 1)
  assert.equal(results[0], true)
})

test("a sound is allowed again once the cooldown window has elapsed", () => {
  const state = createCooldownState()
  const cooldownMs = {high: 1000, low: 1000}

  assert.equal(shouldPlaySound(state, "channel:1", "high", 0, cooldownMs), true)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 999, cooldownMs), false)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 1000, cooldownMs), true)
})

test("different conversations are grouped independently — a burst in one does not silence another", () => {
  const state = createCooldownState()
  const cooldownMs = {high: 1000, low: 1000}

  assert.equal(shouldPlaySound(state, "channel:1", "high", 0, cooldownMs), true)
  assert.equal(shouldPlaySound(state, "channel:2", "high", 50, cooldownMs), true)
  assert.equal(shouldPlaySound(state, "channel:1", "high", 100, cooldownMs), false)
  assert.equal(shouldPlaySound(state, "channel:2", "high", 100, cooldownMs), false)
})

test("high-priority (mention/DM) cooldown is shorter/less aggressive than low-priority", () => {
  const state = createCooldownState()

  assert.ok(DEFAULT_COOLDOWN_MS.high < DEFAULT_COOLDOWN_MS.low)

  assert.equal(shouldPlaySound(state, "channel:1", "high", 0), true)
  assert.equal(shouldPlaySound(state, "channel:1", "high", DEFAULT_COOLDOWN_MS.high), true)
})

test("an unrecognized priority falls back to the low-priority (more conservative) window", () => {
  const state = createCooldownState()
  const cooldownMs = {high: 1000, low: 5000}

  assert.equal(shouldPlaySound(state, "channel:1", "medium", 0, cooldownMs), true)
  assert.equal(shouldPlaySound(state, "channel:1", "medium", 1500, cooldownMs), false)
  assert.equal(shouldPlaySound(state, "channel:1", "medium", 5000, cooldownMs), true)
})
