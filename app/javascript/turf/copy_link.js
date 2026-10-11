// The rule behind the copy-link controller. No DOM.

// How long the button says "Copied!", in milliseconds.
export const COPIED_MS = 1500

// The button's look: its class swaps from btn-primary to btn-secondary while
// copied.
export function copyLook(copied) {
  return copied
    ? { add: "btn-secondary", remove: "btn-primary" }
    : { add: "btn-primary", remove: "btn-secondary" }
}
