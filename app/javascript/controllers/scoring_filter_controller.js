import { Controller } from "@hotwired/stimulus"
import { cardVisible } from "turf/scoring"

// The goal console's toolbar: hides each card whose data-search does not
// contain the query, and each finished one (data-done) while "Hide finished"
// is ticked.
//
// Both answers live in the fields, so connect reads them. Bind reset to
// turbo:before-cache@document so a restored page starts unfiltered.
export default class extends Controller {
  static targets = [ "query", "hideDone", "card" ]

  connect() {
    this.update()
  }

  update() {
    const query = this.queryTarget.value
    const hideDone = this.hideDoneTarget.checked
    this.cardTargets.forEach((card) => {
      card.hidden = !cardVisible({ search: card.dataset.search, query, hideDone, done: card.dataset.done === "true" })
    })
  }

  reset() {
    this.queryTarget.value = ""
    this.hideDoneTarget.checked = false
    this.update()
  }
}
