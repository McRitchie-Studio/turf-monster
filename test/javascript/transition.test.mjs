import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { transitionPlan, durationMs } = await loadTurfModule("transition")

test("a plan reads the three class lists for its direction", () => {
  const dataset = {
    transitionEnter: "transition ease-out duration-150",
    transitionEnterStart: "opacity-0 scale-95",
    transitionEnterEnd: "opacity-100  scale-100",
    transitionLeave: "transition ease-in duration-100"
  }
  assert.deepEqual(transitionPlan(dataset, "enter"), {
    during: [ "transition", "ease-out", "duration-150" ],
    start: [ "opacity-0", "scale-95" ],
    end: [ "opacity-100", "scale-100" ]
  })
  assert.deepEqual(transitionPlan(dataset, "leave"), { during: [ "transition", "ease-in", "duration-100" ], start: [], end: [] })
})

test("a direction with no classes has no plan, so the change is immediate", () => {
  assert.equal(transitionPlan({ transitionEnter: "qp-enter" }, "leave"), null)
  assert.equal(transitionPlan({}, "enter"), null)
})

test("a run lasts its duration plus its delay, in either unit", () => {
  assert.equal(durationMs("0.15s", "0s"), 150)
  assert.equal(durationMs("100ms", "50ms"), 150)
  assert.equal(durationMs("0.2s, 0.4s", "0s"), 200)
  assert.equal(durationMs("", undefined), 0)
})
