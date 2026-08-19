// Pure ConnectionLiveness decision logic: no DOM/timer/WebSocket dependency,
// so it's unit-testable (see connection_liveness.test.mjs) without standing
// up a LiveSocket. Consumed only by the ConnectionState hook in app.js, which
// owns the actual `window`/`document` listeners, the ping round trip, and the
// setInterval driving the suspend-detection tick.

export const PROBE_COOLDOWN_MS = 3_000
export const PING_TIMEOUT_MS = 4_000
export const SUSPEND_TICK_MS = 15_000
export const SUSPEND_GAP_MULTIPLIER = 2

export const createLivenessState = () => ({lastProbeAt: -Infinity})

// Coalesces a burst of lifecycle signals (e.g. "focus" and "visibilitychange"
// firing together on tab switch) into a single liveness probe. Mutates
// `state` like sound_cooldown's shouldPlaySound: true means go ahead and
// probe now (already recorded), false means fold into the recent attempt.
export const shouldProbe = (state, now, cooldownMs = PROBE_COOLDOWN_MS) => {
  if (now - state.lastProbeAt < cooldownMs) return false
  state.lastProbeAt = now
  return true
}

// No native "woke from sleep" browser event exists. A recurring timer whose
// actual gap between ticks is much larger than scheduled implies the tab/OS
// was suspended in between — ordinary jitter/GC pauses stay well under 2x.
export const suspectedSuspend = (
  expectedIntervalMs,
  actualElapsedMs,
  multiplier = SUSPEND_GAP_MULTIPLIER
) => actualElapsedMs >= expectedIntervalMs * multiplier
