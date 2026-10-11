import { Controller } from "@hotwired/stimulus"
import { MASK, canScrollRight } from "turf/contest_rail"

// The featured rail's right-edge fade: on while the rail has more to show to
// the right, off at its end or when it fits. Measured on connect, on every
// scroll, and whenever the viewport's box changes size.
//
// The measure lives in the controller; disconnect stops the observer.
export default class extends Controller {
  static targets = [ "viewport" ]

  connect() {
    this.measure()
    if (window.ResizeObserver && this.hasViewportTarget) {
      this.observer = new ResizeObserver(() => this.measure())
      this.observer.observe(this.viewportTarget)
    }
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
    this.observer = null
  }

  measure() {
    if (!this.hasViewportTarget) return
    const el = this.viewportTarget
    const mask = canScrollRight(el) ? MASK : ""
    el.style.setProperty("-webkit-mask-image", mask)
    el.style.setProperty("mask-image", mask)
  }
}
