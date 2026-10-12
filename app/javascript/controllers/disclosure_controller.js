import { Controller } from "@hotwired/stimulus"
import { enter, leave, settle } from "turf/enter_leave"

// A panel a trigger opens and closes: a menu, a tooltip, a popover. The panel
// may name enter and leave classes (data-enter, data-leave and their -start and
// -end, run by turf/enter_leave), and animates with them.
//
// Bind outside to click@window so a press anywhere but the panel and its
// triggers closes it; bind close to keydown.esc@window where Escape closes it.
//
// The markup is the state: the panel hidden, each trigger aria-expanded="false".
// Bind reset to turbo:before-cache@document so a restored page starts closed;
// disconnect ends any run in flight.
export default class extends Controller {
  static targets = [ "panel", "trigger" ]

  connect() {
    this.shown = this.hasPanelTarget && !this.panelTarget.hidden
  }

  disconnect() {
    this.panelTargets.forEach((panel) => settle(panel, this.shown))
  }

  // Open from the moment show runs until hide runs, so a press during the
  // leave reopens the panel rather than leaving it again.
  get open() {
    return this.hasPanelTarget && this.shown
  }

  toggle() {
    this.open ? this.hide() : this.show()
  }

  close() {
    if (this.open) this.hide()
  }

  outside(event) {
    if (!this.open) return
    const inside = [ ...this.panelTargets, ...this.triggerTargets ].some((el) => el.contains(event.target))
    if (!inside) this.hide()
  }

  reset() {
    this.shown = false
    this.panelTargets.forEach((panel) => settle(panel, false))
    this.expanded(false)
  }

  show() {
    this.shown = true
    this.expanded(true)
    enter(this.panelTarget)
  }

  hide() {
    this.shown = false
    this.expanded(false)
    leave(this.panelTarget)
  }

  expanded(open) {
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", String(open)))
  }
}
