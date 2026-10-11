// The rule behind the frame-reload controller: how a turbo-frame fetches itself
// again. No DOM.

// A frame that has a src reloads it; one rendered inline is given `fallback`
// as its src, which makes Turbo fetch it.
export function reloadPlan(frameSrc, fallback) {
  return frameSrc ? { reload: true } : { src: fallback }
}
