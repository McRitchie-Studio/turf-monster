import { Controller } from "@hotwired/stimulus"
import { sendBlocked } from "turf/send_gate"

// Keeps a form's submit disabled until the typed count matches (and, when the
// form needs it, "Send early" is ticked), and puts a confirm in front of the
// submit.
export default class extends Controller {
  static targets = [ "typed", "early", "submit" ]
  static values = { count: Number, needsEarly: Boolean, confirm: String }

  // Starts empty and unticked, whatever a restored page left in the fields.
  connect() {
    this.typedTarget.value = ""
    if (this.hasEarlyTarget) this.earlyTarget.checked = false
    this.update()
  }

  update() {
    this.submitTarget.disabled = sendBlocked({
      count: this.countValue,
      typed: this.typedTarget.value,
      needsEarly: this.needsEarlyValue,
      early: this.hasEarlyTarget && this.earlyTarget.checked
    })
  }

  confirm(event) {
    if (!window.confirm(this.confirmValue)) event.preventDefault()
  }
}
