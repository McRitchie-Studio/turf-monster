import { Controller } from "@hotwired/stimulus"
import { toggled } from "turf/accordion"

// One section open at a time. Each button names its section with
// data-accordion-key-param; each panel and chevron carries data-key.
//
// The markup is the state: every panel hidden. Bind collapse to
// turbo:before-cache@document so a restored page starts with all closed.
export default class extends Controller {
  static targets = [ "panel", "icon" ]

  toggle({ params: { key } }) {
    this.render(toggled(this.open, key))
  }

  collapse() {
    this.render(null)
  }

  get open() {
    const shown = this.panelTargets.find((panel) => !panel.hidden)
    return shown ? shown.dataset.key : null
  }

  render(open) {
    this.panelTargets.forEach((panel) => { panel.hidden = panel.dataset.key !== open })
    this.iconTargets.forEach((icon) => { icon.classList.toggle("rotate-180", icon.dataset.key === open) })
  }
}
