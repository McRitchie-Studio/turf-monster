import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { enter, leave, settle, phaseClasses, durationOf, DEFAULT_MS } = await loadTurfModule("enter_leave")

function element(dataset, hidden = true) {
  const classes = new Set()
  return {
    dataset,
    hidden,
    classList: {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name))
    },
    get classes() { return [ ...classes ].sort() }
  }
}

// Frames and timers that run only when the test says so.
function manual() {
  const frames = []
  const timers = []
  return {
    frames, timers,
    frame: (callback) => frames.push(callback),
    later: (callback, ms) => timers.push({ callback, ms }),
    runFrame() { frames.shift()() },
    runTimer() { return timers.shift() }
  }
}

const DATASET = {
  enter: "transition ease-out duration-150", enterStart: "opacity-0", enterEnd: "opacity-100",
  leave: "transition ease-in duration-100", leaveStart: "opacity-100", leaveEnd: "opacity-0"
}

test("a phase's classes are read from the dataset", () => {
  assert.deepEqual(phaseClasses(DATASET, "enter"), { during: [ "transition", "ease-out", "duration-150" ], start: [ "opacity-0" ], end: [ "opacity-100" ] })
  assert.deepEqual(phaseClasses({}, "leave"), { during: [], start: [], end: [] })
})

test("the duration comes from a duration class, else the default", () => {
  assert.equal(durationOf([ "transition", "duration-75" ]), 75)
  assert.equal(durationOf([ "transition" ]), DEFAULT_MS)
})

test("enter shows at once with the start classes, swaps to end on the next frame, and cleans up", () => {
  const el = element(DATASET)
  const clock = manual()
  enter(el, clock)
  assert.equal(el.hidden, false)
  assert.deepEqual(el.classes, [ "duration-150", "ease-out", "opacity-0", "transition" ])
  clock.runFrame()
  assert.deepEqual(el.classes, [ "duration-150", "ease-out", "opacity-100", "transition" ])
  const timer = clock.runTimer()
  assert.equal(timer.ms, 150)
  timer.callback()
  assert.deepEqual(el.classes, [])
  assert.equal(el.hidden, false)
})

test("leave stays visible until its duration has passed, then hides", () => {
  const el = element(DATASET, false)
  const clock = manual()
  leave(el, clock)
  clock.runFrame()
  assert.equal(el.hidden, false)
  assert.deepEqual(el.classes, [ "duration-100", "ease-in", "opacity-0", "transition" ])
  const timer = clock.runTimer()
  assert.equal(timer.ms, 100)
  timer.callback()
  assert.equal(el.hidden, true)
  assert.deepEqual(el.classes, [])
})

test("an enter during a leave cancels the leave, so the element stays shown", () => {
  const el = element(DATASET, false)
  const clock = manual()
  leave(el, clock)
  clock.runFrame()
  const leaving = clock.runTimer()
  enter(el, clock)
  leaving.callback()
  assert.equal(el.hidden, false)
})

test("settle cancels a running phase and sets the state at once", () => {
  const el = element(DATASET, true)
  const clock = manual()
  enter(el, clock)
  settle(el, false)
  clock.runFrame()
  assert.equal(clock.timers.length, 0)
  assert.equal(el.hidden, true)
  assert.deepEqual(el.classes, [])
})

// The start-time tooltip names enter classes and no leave ones: its close has
// nothing to animate, so it must not wait out a default duration first.
test("a phase that names no classes lands at once, with nothing scheduled", () => {
  const el = element({ enter: "transition duration-150", enterStart: "opacity-0", enterEnd: "opacity-100" }, false)
  const clock = manual()
  leave(el, clock)
  assert.equal(el.hidden, true)
  assert.equal(clock.frames.length, 0)

  const bare = element({}, true)
  enter(bare, clock)
  assert.equal(bare.hidden, false)
  assert.equal(clock.frames.length, 0)
})

test("a leave with no classes cancels an enter still running", () => {
  const el = element({ enter: "transition duration-150", enterStart: "opacity-0", enterEnd: "opacity-100" }, true)
  const clock = manual()
  enter(el, clock)
  leave(el, clock)
  clock.runFrame()
  assert.equal(el.hidden, true)
  assert.deepEqual(el.classes, [])
  assert.equal(clock.timers.length, 0)
})
