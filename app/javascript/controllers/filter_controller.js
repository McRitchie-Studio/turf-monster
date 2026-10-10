import { Controller } from "@hotwired/stimulus"
import { matches } from "turf/filter"

// Filters a list by a text input: hides each item whose data-filter-text does
// not contain the query, shows a clear button while there is a query, and an
// empty state when nothing matches.
//
// The query lives in the input, so connect reads it. Bind reset to
// turbo:before-cache@document so a restored page starts unfiltered.
export default class extends Controller {
  static targets = [ "input", "clear", "item", "empty", "query" ]

  connect() {
    this.update()
  }

  update() {
    const query = this.inputTarget.value
    let visible = 0
    this.itemTargets.forEach((item) => {
      const show = matches(item.dataset.filterText, query)
      item.hidden = !show
      if (show) visible += 1
    })
    this.clearTargets.forEach((button) => { button.hidden = query.length === 0 })
    this.queryTargets.forEach((element) => { element.textContent = query })
    this.emptyTargets.forEach((element) => { element.hidden = !(query && visible === 0) })
  }

  clear(event) {
    if (event.type === "keydown") event.preventDefault()
    this.reset()
  }

  reset() {
    this.inputTarget.value = ""
    this.update()
  }
}
