import { Controller } from "@hotwired/stimulus"
import { COPIED_MS, copyLook } from "turf/copy_link"

// Copies a link on a press and says "Copied!" for a moment. Any element may
// press it; the button target changes its look and swaps its two labels.
//
// The markup is the state: the idle label shown, the copied one hidden. Bind
// reset to turbo:before-cache@document so a restored page starts idle;
// disconnect clears the timer.
export default class extends Controller {
  static targets = [ "button", "idle", "done" ]
  static values = { text: String }

  disconnect() {
    clearTimeout(this.timer)
  }

  copy() {
    navigator.clipboard.writeText(this.textValue)
    this.render(true)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.render(false), COPIED_MS)
  }

  reset() {
    clearTimeout(this.timer)
    this.render(false)
  }

  render(copied) {
    const look = copyLook(copied)
    this.buttonTargets.forEach((button) => {
      button.classList.remove(look.remove)
      button.classList.add(look.add)
    })
    this.idleTargets.forEach((label) => { label.hidden = copied })
    this.doneTargets.forEach((label) => { label.hidden = !copied })
  }
}
