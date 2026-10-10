// The seeds loader lab's state and what it draws. No DOM.
//
// 100 seeds is a level and 20 seeds a section. `seeds` is the true total;
// `displaySeeds` (0..100) and `displayLevel` are what the bars show, and lag it
// through a level-up.

export const SHINE_MODES = [ "continuous", "pulse", "once", "off" ]

export function initialState() {
  return {
    seeds: 0,
    displaySeeds: 0,
    displayLevel: 1,
    levelingUp: false,
    shineMode: "continuous",
    shineInterval: 5,
    shineDelay: 0,
    shineVisible: true
  }
}

export function level(seeds) {
  return Math.floor(seeds / 100) + 1
}

export function towardNext(seeds) {
  return seeds % 100
}

export function sectionsFilled(displaySeeds) {
  return Math.floor(displaySeeds / 20)
}

// How full section `index` (1..5) is, 0..100.
export function sectionFill(displaySeeds, index) {
  return Math.max(0, Math.min(100, (displaySeeds - (index - 1) * 20) * 5))
}

// Adds seeds. Returns the next state and, when the total crosses a level, the
// level to run the level-up sequence for.
export function add(state, amount) {
  if (state.levelingUp) return { state, levelUp: null }

  const before = level(state.seeds)
  const seeds = state.seeds + amount
  const after = level(seeds)
  if (after > before) return { state: { ...state, seeds }, levelUp: after }

  return { state: { ...state, seeds, displaySeeds: towardNext(seeds), displayLevel: after }, levelUp: null }
}

// Sets the progress inside the current level, never crossing it.
export function jumpTo(state, target) {
  if (state.levelingUp) return state

  const base = Math.floor(state.seeds / 100) * 100
  const seeds = base + Math.min(99, Math.max(0, target))
  return { ...state, seeds, displaySeeds: towardNext(seeds), displayLevel: level(seeds) }
}

export function reset(state) {
  if (state.levelingUp) return state
  return { ...state, seeds: 0, displaySeeds: 0, displayLevel: 1 }
}

// The level-up sequence: each step is the state change to make `at`
// milliseconds after it starts. Fill, bump the level, drain, refill.
export function levelUpSteps(newLevel, seeds) {
  return [
    { at: 0, change: { levelingUp: true, displaySeeds: 100 } },
    { at: 1500, change: { displayLevel: newLevel } },
    { at: 2800, change: { displaySeeds: 0 } },
    { at: 3000, change: { displaySeeds: towardNext(seeds), levelingUp: false } }
  ]
}

// The CSS animation of variant 1's shimmer.
export function shine(state) {
  const pulse = state.shineMode === "pulse"
  const once = state.shineMode === "once"
  return {
    shown: state.shineVisible && state.shineMode !== "off",
    animationName: pulse ? "seedsShimmerPulse" : "seedsShimmer",
    animationDuration: (pulse ? state.shineInterval : 2.5) + "s",
    animationTimingFunction: "ease-in-out",
    animationDelay: state.shineDelay + "s",
    animationIterationCount: once ? "1" : "infinite",
    animationFillMode: once ? "forwards" : "none"
  }
}

export function shineDebug(state) {
  if (state.shineMode === "off") return "animation: none"
  const css = shine(state)
  return `${css.animationName} ${css.animationDuration} ease-in-out ${css.animationDelay} ${css.animationIterationCount}`
}

// Every text the page prints from the state, by its data-label.
export function labels(state) {
  const { displaySeeds, displayLevel } = state
  const filled = sectionsFilled(displaySeeds)
  return {
    seeds: String(state.seeds),
    level: String(displayLevel),
    toward: String(displaySeeds),
    levelBadge: "Level " + displayLevel,
    sections: filled + " / 5 sections",
    seedsOf: displaySeeds + " / 100 seeds",
    counter: displaySeeds + " / 100",
    grown: filled + " of 5 grown",
    cells: filled + " / 5 cells",
    shineInterval: state.shineInterval + "s",
    shineIntervalHint: "(shine ≈ " + (state.shineInterval * 0.25).toFixed(1) + "s)",
    shineDelay: state.shineDelay + "s",
    shineDebug: shineDebug(state)
  }
}

// Every inline style the page sets from the state, by its data-style.
export function styles(state) {
  const { displaySeeds } = state
  return {
    progress: { "--bar-progress": String(displaySeeds) },
    roller: { transform: "translateY(-" + (displaySeeds * 1.25) + "em)" },
    fill: { width: displaySeeds + "%" },
    fillShimmer: { left: Math.max(0, displaySeeds - 40) + "%" },
    counterClip: { "clip-path": "inset(0 " + (100 - displaySeeds) + "% 0 0)" }
  }
}

// One sprout of variant 3, for section `index` (1..5).
export function sprout(displaySeeds, index) {
  const grown = sectionFill(displaySeeds, index) >= 100
  return {
    text: grown ? "🌳" : "🌱",
    transform: grown ? "scale(1.15)" : "scale(0.85)",
    filter: grown ? "grayscale(0) opacity(1)" : "grayscale(0.7) opacity(0.45)"
  }
}
