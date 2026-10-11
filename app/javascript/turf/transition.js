// The rule behind a show or hide that animates, the way Alpine's x-transition
// did. No DOM.
//
// An element names its classes in data attributes, per direction:
//   data-transition-enter / -enter-start / -enter-end
//   data-transition-leave / -leave-start / -leave-end
// `during` stays on for the whole run, `start` for the first frame, and `end`
// from the second frame until the run is over.

const words = (text) => (text || "").split(/\s+/).filter(Boolean)

// The three class lists for one direction ("enter" or "leave"), read from an
// element's dataset; null when it names none, so the change is immediate.
export function transitionPlan(dataset, direction) {
  const key = direction === "enter" ? "Enter" : "Leave"
  const plan = {
    during: words(dataset[`transition${key}`]),
    start: words(dataset[`transition${key}Start`]),
    end: words(dataset[`transition${key}End`])
  }
  return plan.during.length || plan.start.length || plan.end.length ? plan : null
}

// How long a run lasts, in milliseconds, from the computed transition-duration
// and transition-delay ("0.15s", "150ms", or a list whose first entry counts).
export function durationMs(duration, delay) {
  const ms = (value) => {
    const first = String(value || "0s").split(",")[0].trim()
    const number = parseFloat(first) || 0
    return first.endsWith("ms") ? number : number * 1000
  }
  return ms(duration) + ms(delay)
}
