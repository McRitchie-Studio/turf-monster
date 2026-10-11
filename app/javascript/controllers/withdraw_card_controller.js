import { Controller } from "@hotwired/stimulus"
import { canSubmit, openAtStart, toggleLabel } from "turf/withdraw_card"
import { enter, leave, settle } from "turf/enter_leave"

// The cash-out card: its Withdraw button opens the form (and reads Cancel to
// close it), the page opens it when reached at #cash-out, and the submit waits
// for an amount and a destination. The form posts as before; this only shows
// and enables it.
//
// The markup is the state: form hidden, submit disabled. connect reads both
// fields, so what was typed before it connected counts. Bind reset to
// turbo:before-cache@document so a restored page starts as a fresh one:
// closed, with both fields empty.
export default class extends Controller {
  static targets = [ "toggle", "panel", "amount", "destination", "submit" ]
  static values = { frozen: Boolean }

  connect() {
    if (this.panelTarget.hidden && openAtStart({ hash: window.location.hash, frozen: this.frozenValue })) {
      settle(this.panelTarget, true)
    }
    this.renderToggle()
    this.validate()
  }

  toggle() {
    if (this.panelTarget.hidden || this.closing) {
      this.closing = false
      enter(this.panelTarget)
    } else {
      this.closing = true
      leave(this.panelTarget)
    }
    this.renderToggle()
  }

  validate() {
    if (this.hasSubmitTarget) this.submitTarget.disabled = !canSubmit(this.amountTarget.value, this.destinationTarget.value)
  }

  reset() {
    this.closing = false
    settle(this.panelTarget, false)
    this.amountTarget.value = this.amountTarget.defaultValue
    this.destinationTarget.value = this.destinationTarget.defaultValue
    this.renderToggle()
    this.validate()
  }

  get open() {
    return !this.panelTarget.hidden && !this.closing
  }

  renderToggle() {
    if (this.hasToggleTarget) this.toggleTarget.textContent = toggleLabel(this.open)
  }
}
