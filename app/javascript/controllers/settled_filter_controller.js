import { Controller } from "@hotwired/stimulus"
import { toggleLook } from "turf/settled_filter"

// The lobby's admin Show Settled toggle: it reveals the settled rows of the All
// Contests table, and hides the "No open contests" note while they show.
//
// The markup is the state: settled rows hidden, the toggle aria-pressed="false".
// Bind reset to turbo:before-cache@document so a restored page starts hidden.
export default class extends Controller {
  static targets = [ "toggle", "row", "empty" ]

  get showing() {
    return this.hasToggleTarget && this.toggleTarget.getAttribute("aria-pressed") === "true"
  }

  toggle() {
    this.render(!this.showing)
  }

  reset() {
    this.render(false)
  }

  render(show) {
    const look = toggleLook(show)
    this.toggleTargets.forEach((toggle) => {
      toggle.className = look.className
      toggle.textContent = look.text
      toggle.setAttribute("aria-pressed", look.pressed)
    })
    this.rowTargets.forEach((row) => { row.hidden = !show })
    this.emptyTargets.forEach((note) => { note.hidden = show })
  }
}
