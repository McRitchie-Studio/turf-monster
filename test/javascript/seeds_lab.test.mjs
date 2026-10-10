import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const lab = await loadTurfModule("seeds_lab")
const start = lab.initialState()

test("the lab starts empty, at level 1, on a continuous shine", () => {
  assert.deepEqual(start, {
    seeds: 0, displaySeeds: 0, displayLevel: 1, levelingUp: false,
    shineMode: "continuous", shineInterval: 5, shineDelay: 0, shineVisible: true
  })
})

test("adding inside a level moves the bar at once", () => {
  const { state, levelUp } = lab.add(start, 25)
  assert.equal(levelUp, null)
  assert.deepEqual([ state.seeds, state.displaySeeds, state.displayLevel ], [ 25, 25, 1 ])
})

test("crossing a level holds the bar and names the level to run", () => {
  const at95 = lab.jumpTo(start, 95)
  const { state, levelUp } = lab.add(at95, 19)
  assert.equal(levelUp, 2)
  assert.deepEqual([ state.seeds, state.displaySeeds, state.displayLevel ], [ 114, 95, 1 ])
})

test("the level-up fills, bumps the level, drains and refills to the leftover", () => {
  assert.deepEqual(lab.levelUpSteps(2, 114), [
    { at: 0, change: { levelingUp: true, displaySeeds: 100 } },
    { at: 1500, change: { displayLevel: 2 } },
    { at: 2800, change: { displaySeeds: 0 } },
    { at: 3000, change: { displaySeeds: 14, levelingUp: false } }
  ])
})

test("nothing moves the total while a level-up runs", () => {
  const busy = { ...start, seeds: 114, levelingUp: true }
  assert.equal(lab.add(busy, 25).state, busy)
  assert.equal(lab.jumpTo(busy, 95), busy)
  assert.equal(lab.reset(busy), busy)
})

test("a jump stays inside the current level", () => {
  const level3 = { ...start, seeds: 230, displaySeeds: 30, displayLevel: 3 }
  assert.deepEqual(pick(lab.jumpTo(level3, 95)), [ 295, 95, 3 ])
  assert.deepEqual(pick(lab.jumpTo(level3, 400)), [ 299, 99, 3 ])
  assert.deepEqual(pick(lab.jumpTo(level3, -5)), [ 200, 0, 3 ])
})

test("reset returns to zero and keeps the shine settings", () => {
  const state = lab.reset({ ...start, seeds: 230, displaySeeds: 30, displayLevel: 3, shineMode: "pulse" })
  assert.deepEqual(pick(state), [ 0, 0, 1 ])
  assert.equal(state.shineMode, "pulse")
})

test("a section is 20 seeds", () => {
  assert.deepEqual([ 1, 2, 3, 4, 5 ].map((index) => lab.sectionFill(50, index)), [ 100, 100, 50, 0, 0 ])
  assert.equal(lab.sectionsFilled(59), 2)
  assert.equal(lab.sectionsFilled(100), 5)
})

test("a sprout grows when its section is full", () => {
  assert.deepEqual(lab.sprout(40, 2), { text: "🌳", transform: "scale(1.15)", filter: "grayscale(0) opacity(1)" })
  assert.deepEqual(lab.sprout(39, 2), { text: "🌱", transform: "scale(0.85)", filter: "grayscale(0.7) opacity(0.45)" })
})

test("the labels print every text the page shows", () => {
  assert.deepEqual(lab.labels({ ...start, seeds: 144, displaySeeds: 44, displayLevel: 2, shineInterval: 5.5, shineDelay: 1 }), {
    seeds: "144",
    level: "2",
    toward: "44",
    levelBadge: "Level 2",
    sections: "2 / 5 sections",
    seedsOf: "44 / 100 seeds",
    counter: "44 / 100",
    grown: "2 of 5 grown",
    cells: "2 / 5 cells",
    shineInterval: "5.5s",
    shineIntervalHint: "(shine ≈ 1.4s)",
    shineDelay: "1s",
    shineDebug: "seedsShimmer 2.5s ease-in-out 1s infinite"
  })
})

test("the styles follow the bar", () => {
  assert.deepEqual(lab.styles({ ...start, displaySeeds: 44 }), {
    progress: { "--bar-progress": "44" },
    roller: { transform: "translateY(-55em)" },
    fill: { width: "44%" },
    fillShimmer: { left: "4%" },
    counterClip: { "clip-path": "inset(0 56% 0 0)" }
  })
  assert.equal(lab.styles({ ...start, displaySeeds: 20 }).fillShimmer.left, "0%")
})

test("each shine mode has its own animation", () => {
  const shine = (change) => lab.shine({ ...start, ...change })
  assert.deepEqual(shine({}), {
    shown: true, animationName: "seedsShimmer", animationDuration: "2.5s", animationTimingFunction: "ease-in-out",
    animationDelay: "0s", animationIterationCount: "infinite", animationFillMode: "none"
  })
  assert.deepEqual(pickShine(shine({ shineMode: "pulse", shineInterval: 8 })), [ true, "seedsShimmerPulse", "8s", "infinite", "none" ])
  assert.deepEqual(pickShine(shine({ shineMode: "once", shineDelay: 2 })), [ true, "seedsShimmer", "2.5s", "1", "forwards" ])
  assert.equal(shine({ shineMode: "off" }).shown, false)
  assert.equal(shine({ shineVisible: false }).shown, false)
})

test("the debug line reads the active animation", () => {
  assert.equal(lab.shineDebug({ ...start, shineMode: "off" }), "animation: none")
  assert.equal(lab.shineDebug({ ...start, shineMode: "pulse", shineInterval: 8, shineDelay: 0.5 }), "seedsShimmerPulse 8s ease-in-out 0.5s infinite")
  assert.equal(lab.shineDebug({ ...start, shineMode: "once" }), "seedsShimmer 2.5s ease-in-out 0s 1")
})

function pick(state) {
  return [ state.seeds, state.displaySeeds, state.displayLevel ]
}

function pickShine(css) {
  return [ css.shown, css.animationName, css.animationDuration, css.animationIterationCount, css.animationFillMode ]
}
