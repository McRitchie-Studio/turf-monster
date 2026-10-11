// Shows and hides an element with an enter or leave transition, the way
// Alpine's x-transition does: the "during" and "start" classes first, "end" on
// the next frame, and all of them gone once the duration has passed. The
// classes are read from the element's data-enter, data-enter-start,
// data-enter-end, data-leave, data-leave-start and data-leave-end attributes.
//
// It touches only the element it is given and the two schedulers, so a test
// can pass stand-ins for all three.

export const DEFAULT_MS = 150

function classes(value) {
  return (value || "").split(/\s+/).filter(Boolean)
}

// The class lists of one phase ("enter" or "leave").
export function phaseClasses(dataset, phase) {
  return {
    during: classes(dataset[phase]),
    start: classes(dataset[`${phase}Start`]),
    end: classes(dataset[`${phase}End`])
  }
}

// The duration a class list names (duration-150 is 150 ms).
export function durationOf(list) {
  const named = list.map((name) => /^duration-(\d+)$/.exec(name)).find(Boolean)
  return named ? Number(named[1]) : DEFAULT_MS
}

const defaults = () => ({
  frame: (callback) => requestAnimationFrame(callback),
  later: (callback, ms) => setTimeout(callback, ms)
})

// Runs one phase on `el`. A later call cancels an earlier one still running.
export function transition(el, phase, scheduler = defaults()) {
  const { during, start, end } = phaseClasses(el.dataset, phase)
  const token = {}
  el.__enterLeave = token
  const live = () => el.__enterLeave === token
  const strip = () => el.classList.remove(...during, ...start, ...end)

  strip()
  el.classList.add(...during, ...start)
  if (phase === "enter") el.hidden = false
  scheduler.frame(() => {
    if (!live()) return
    el.classList.remove(...start)
    el.classList.add(...end)
    scheduler.later(() => {
      if (!live()) return
      if (phase === "leave") el.hidden = true
      strip()
    }, durationOf(during))
  })
}

export function enter(el, scheduler) {
  transition(el, "enter", scheduler)
}

export function leave(el, scheduler) {
  transition(el, "leave", scheduler)
}

// Shows or hides `el` at once, cancelling any phase still running: for a reset
// and for the state a page starts in.
export function settle(el, shown) {
  el.__enterLeave = null
  for (const phase of [ "enter", "leave" ]) {
    const { during, start, end } = phaseClasses(el.dataset, phase)
    el.classList.remove(...during, ...start, ...end)
  }
  el.hidden = !shown
}
