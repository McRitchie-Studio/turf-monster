// The rule behind the submit-busy controller: what a form shows across Turbo's
// submit events. No DOM.

// The answer rack-attack gives a throttled request, before any controller runs.
export const THROTTLED_STATUS = 429

// The state after `phase` ("start" or "end"). A submit that starts clears the
// last refusal; one that ends is throttled only when the server said so.
export function submitState(phase, status) {
  if (phase === "start") return { busy: true, throttled: false }
  return { busy: false, throttled: status === THROTTLED_STATUS }
}

export const IDLE = Object.freeze({ busy: false, throttled: false })
