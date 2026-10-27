// Importmap pins whose NAME is not a path (config/importmap.rb's `to:` aliases),
// which the engine's prefix hook cannot map. Only the ones a module under test
// reaches are listed, each to a stub, because the real file is a vendored
// browser library with no business running in node.
//
//   "canvas-confetti" (studio-engine pins it to studio/canvas_confetti.js): the
//   import "studio/studio_confetti" makes for its side effect. The stub defines
//   nothing, so a test that wants a burst sets window.confetti itself, as the
//   real library would.
const ALIASES = {
  "canvas-confetti": new URL("./stubs/canvas_confetti.mjs", import.meta.url).href
}

export async function resolve(specifier, context, nextResolve) {
  const url = ALIASES[specifier]
  if (url) return { url, format: "module", shortCircuit: true }
  return nextResolve(specifier, context)
}
