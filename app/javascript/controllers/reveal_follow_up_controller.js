import { Controller } from "@hotwired/stimulus"

// The way on from a one-time reveal: hidden while the reveal (`selector`) is in
// the same turbo-frame, shown once it is gone. Turbo drops a
// data-turbo-temporary reveal from the snapshot, so the card Back restores has
// no reveal and shows this. Rendered hidden; bind reset to
// turbo:before-cache@document so the snapshot starts hidden, and connect asks
// the DOM that is really there.
export default class extends Controller {
  static values = { selector: String }

  connect() {
    const scope = this.element.closest("turbo-frame") || document
    this.element.hidden = !!scope.querySelector(this.selectorValue)
  }

  reset() {
    this.element.hidden = true
  }
}
