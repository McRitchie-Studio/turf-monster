// The rule behind the swatch-copy controller. No DOM.

// How long "Copied!" stays on a swatch, in milliseconds.
export const COPIED_MS = 1100

// A swatch's tip: shown while the swatch is hovered or just copied, and
// reading "Copied!" while its hex is the one last copied.
export function tipState({ hex, hovered, copied }) {
  return {
    shown: Boolean(hovered) || copied === hex,
    text: copied === hex ? "Copied!" : hex
  }
}
