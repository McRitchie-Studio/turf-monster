import { Controller } from "@hotwired/stimulus"
import { durationMs, transitionPlan } from "turf/transition"

// A panel a trigger opens and closes: a menu, a tooltip, a popover. The panel
// may name enter and leave classes (turf/transition), and animates with them.
//
// Bind outside to click@window so a press anywhere but the panel and its
// triggers closes it; bind close to keydown.esc@window where Escape closes it.
//
// The markup is the state: the panel hidden, each trigger aria-expanded="false".
// Bind reset to turbo:before-cache@document so a restored page starts closed;
// disconnect clears the timers.
export default class extends Controller {
  static targets = [ "panel", "trigger" ]

  disconnect() {
    this.settle()
  }

  get open() {
    return this.hasPanelTarget && !this.panelTarget.hidden
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
    this.settle()
    this.panelTargets.forEach((panel) => { panel.hidden = true })
    this.expanded(false)
  }

  show() {
    this.settle()
    const panel = this.panelTarget
    panel.hidden = false
    this.expanded(true)
    this.run(panel, transitionPlan(panel.dataset, "enter"))
  }

  hide() {
    this.settle()
    const panel = this.panelTarget
    this.expanded(false)
    this.run(panel, transitionPlan(panel.dataset, "leave"), () => { panel.hidden = true })
  }

  expanded(open) {
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", String(open)))
  }

  // One animated run: `during` and `start` now, `start` swapped for `end` on the
  // next frame, everything off (and `after` called) once it has lasted its
  // duration. With no plan, `after` runs at once.
  run(el, plan, after) {
    if (!plan) { if (after) after(); return }
    el.classList.add(...plan.during, ...plan.start)
    this.running = { el, plan, after }
    this.frame = requestAnimationFrame(() => {
      this.frame = requestAnimationFrame(() => {
        el.classList.remove(...plan.start)
        el.classList.add(...plan.end)
        const style = getComputedStyle(el)
        this.timer = setTimeout(() => this.settle(), durationMs(style.transitionDuration, style.transitionDelay))
      })
    })
  }

  // Ends a run in flight at its end state.
  settle() {
    cancelAnimationFrame(this.frame)
    clearTimeout(this.timer)
    const running = this.running
    this.running = null
    if (!running) return
    const { el, plan, after } = running
    el.classList.remove(...plan.during, ...plan.start, ...plan.end)
    if (after) after()
  }
}
