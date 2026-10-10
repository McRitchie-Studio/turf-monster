// The toast test page's scripted demos. No DOM.
//
// Each demo is a list of steps: the toast `detail` to fire `at` milliseconds
// after the press. A button's `then` is the detail of the toast its press
// fires next.

export function demoSteps(name) {
  const steps = DEMOS[name]
  if (!steps) throw new Error(`unknown toast demo: ${name}`)
  return steps
}

const DEMOS = {
  invite: [ { at: 0, detail: {
    title: "Contest Invite",
    message: "Alex invited you to Matchday 2.",
    image: "/logo.png",
    buttons: [
      { label: "Accept", style: "primary", then: { title: "Accepted!", message: "You joined Matchday 2." } },
      { label: "Decline", style: "outline" }
    ]
  } } ],

  delete: [ { at: 0, detail: {
    type: "alert",
    title: "Clear Picks?",
    message: "This will remove all 6 selections from your entry.",
    buttons: [
      { label: "Clear", style: "danger", then: { type: "alert", title: "Cleared", message: "All picks removed." } },
      { label: "Cancel", style: "outline" }
    ]
  } } ],

  undo: [ { at: 0, detail: {
    title: "Pick Removed",
    message: "USA vs Mexico removed from entry.",
    buttons: [
      { label: "Undo", style: "primary", then: { title: "Restored", message: "Pick added back to entry." } }
    ]
  } } ],

  blurButtons: [ { at: 0, detail: {
    title: "Contest Invite",
    message: "Alex invited you to Matchday 2.",
    image: "/logo.png",
    blurShadow: true,
    buttons: [
      { label: "Accept", style: "primary", then: { title: "Accepted!", message: "You joined Matchday 2.", blurShadow: true } },
      { label: "Decline", style: "outline" }
    ]
  } } ],

  stack: [
    { at: 0, detail: { type: "notice", title: "Step 1", message: "Entry submitted.", duration: 15000 } },
    { at: 300, detail: { type: "notice", title: "Step 2", message: "Payment confirmed.", duration: 15000 } },
    { at: 600, detail: { type: "alert", title: "Warning", message: "Game locks in 5 minutes.", duration: 15000 } }
  ],

  stackSlow: [
    { at: 0, detail: { type: "notice", title: "First", message: "This appears first.", duration: 20000 } },
    { at: 1000, detail: { type: "notice", title: "Second", message: "Pushes first down into a peek strip.", duration: 20000 } },
    { at: 2000, detail: { type: "alert", title: "Third", message: "Now there are 3 stacked. Click a peek to expand.", duration: 20000 } }
  ]
}

export const DEMO_NAMES = Object.keys(DEMOS)
