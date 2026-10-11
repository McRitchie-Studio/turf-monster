import { Controller } from "@hotwired/stimulus"
import { revealState } from "turf/reveal"

// A trigger that gives way to the region it reveals, and focuses the region's
// field. The server renders the open value and the matching hidden attributes;
// bind reset to turbo:before-cache@document so a restored page starts as the
// server rendered it.
export default class extends Controller {
  static targets = [ "trigger", "region", "field" ]
  static values = { open: Boolean }

  open() {
    this.render(true)
    if (this.hasFieldTarget) this.fieldTarget.focus()
  }

  reset() {
    this.render(this.openValue)
  }

  render(open) {
    const { triggerHidden, regionHidden } = revealState(open)
    this.triggerTargets.forEach((el) => { el.hidden = triggerHidden })
    this.regionTargets.forEach((el) => { el.hidden = regionHidden })
  }
}
