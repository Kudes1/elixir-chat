// Sound-spam protection: even a correct per-event "sound" decision from
// notification_policy.js must not turn into N audible beeps for N events in
// a burst from the same conversation. This module is the single place that
// decides "is it too soon to play another sound for this conversation" — it
// never touches whether a badge/toast should show (those still fire once per
// event, exactly as decided by notification_policy.js; only the *sound* is
// throttled).
//
// Deliberately takes `state` and `now` as arguments rather than owning a
// clock/Map internally, so it stays as unit-testable as notification_policy.js
// (see sound_cooldown.test.mjs) without faking Date.now() or a timer.
export const DEFAULT_COOLDOWN_MS = {
  // Mention/DM: a burst of several still collapses to one sound, but the
  // window is short — these are the events users most want to hear about.
  high: 8_000,
  // Kept for symmetry/config completeness: today notification_policy.js never
  // emits "sound" for low-priority events (see its own comments), only
  // "badge". If that ever changes, ordinary messages get the more aggressive
  // (longer) cooldown described in tasks/05-sound-spam-protection.md.
  low: 20_000,
}

export const createCooldownState = () => new Map()

// `key` groups events into the same cooldown bucket — pass the conversation
// (channel/direct) identifier so a burst in one dialog doesn't also silence a
// concurrent, unrelated one.
export const shouldPlaySound = (state, key, priority, now, cooldownMs = DEFAULT_COOLDOWN_MS) => {
  const windowMs = cooldownMs[priority] ?? cooldownMs.low
  const last = state.get(key)

  if (last !== undefined && now - last < windowMs) return false

  state.set(key, now)
  return true
}
