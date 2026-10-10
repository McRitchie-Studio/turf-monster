import { Controller } from "@hotwired/stimulus"
import { COPIED_MS, tipState } from "turf/swatch_copy"

// A strip of colour swatches: each shows its hex on hover, and copies it on a
// press, saying "Copied!" for a moment. Each swatch is a button with data-hex
// holding a tip target.
//
// The markup is the state: every tip hidden. Bind reset to
// turbo:before-cache@document so a restored page starts with every tip hidden;
// disconnect clears the timers.
export default class extends Controller {
  static targets = [ "tip" ]

  connect() {
    this.copied = null
    this.hovered = null
    this.timers = new Set()
  }

  disconnect() {
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers.clear()
  }

  reset() {
    this.copied = null
    this.hovered = null
    this.render()
  }

  hover(event) {
    this.hovered = event.currentTarget
    this.render()
  }

  unhover(event) {
    if (this.hovered === event.currentTarget) this.hovered = null
    this.render()
  }

  copy(event) {
    const hex = event.currentTarget.dataset.hex
    navigator.clipboard.writeText(hex)
    this.copied = hex
    const timer = setTimeout(() => {
      this.timers.delete(timer)
      if (this.copied === hex) this.copied = null
      this.render()
    }, COPIED_MS)
    this.timers.add(timer)
    this.render()
  }

  render() {
    this.tipTargets.forEach((tip) => {
      const swatch = tip.closest("[data-hex]")
      const { shown, text } = tipState({ hex: swatch.dataset.hex, hovered: swatch === this.hovered, copied: this.copied })
      tip.hidden = !shown
      tip.textContent = text
    })
  }
}
