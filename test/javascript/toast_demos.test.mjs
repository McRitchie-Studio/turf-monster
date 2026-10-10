import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { demoSteps, DEMO_NAMES } = await loadTurfModule("toast_demos")

test("the page's six demos are all there", () => {
  assert.deepEqual(DEMO_NAMES, [ "invite", "delete", "undo", "blurButtons", "stack", "stackSlow" ])
})

test("a button demo fires one toast, whose first button names its follow-up", () => {
  const follow = {
    invite: { title: "Accepted!", message: "You joined Matchday 2." },
    delete: { type: "alert", title: "Cleared", message: "All picks removed." },
    undo: { title: "Restored", message: "Pick added back to entry." },
    blurButtons: { title: "Accepted!", message: "You joined Matchday 2.", blurShadow: true }
  }
  for (const [ name, then ] of Object.entries(follow)) {
    const steps = demoSteps(name)
    assert.equal(steps.length, 1, name)
    assert.equal(steps[0].at, 0, name)
    assert.deepEqual(steps[0].detail.buttons[0].then, then, name)
  }
})

test("a second button dismisses and fires nothing", () => {
  assert.deepEqual(demoSteps("invite")[0].detail.buttons[1], { label: "Decline", style: "outline" })
  assert.deepEqual(demoSteps("delete")[0].detail.buttons[1], { label: "Cancel", style: "outline" })
})

test("the stacks fire three toasts on their schedules", () => {
  assert.deepEqual(demoSteps("stack").map((step) => [ step.at, step.detail.title, step.detail.duration ]),
    [ [ 0, "Step 1", 15000 ], [ 300, "Step 2", 15000 ], [ 600, "Warning", 15000 ] ])
  assert.deepEqual(demoSteps("stackSlow").map((step) => [ step.at, step.detail.title, step.detail.duration ]),
    [ [ 0, "First", 20000 ], [ 1000, "Second", 20000 ], [ 2000, "Third", 20000 ] ])
})

test("an unknown demo is refused", () => {
  assert.throws(() => demoSteps("nope"), /unknown toast demo/)
})
