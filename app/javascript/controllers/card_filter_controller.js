import { Controller } from "@hotwired/stimulus"
import { cardVisible, countLabel } from "turf/card_filter"

// Narrows a grid of cards by a search box and by option buttons, and keeps a
// count of the cards left. Each card matches `selector` and carries its
// searchable text in data-name and its value per filter key in data-<key>.
// Each option button names its key and value with data-card-filter-key-param
// and data-card-filter-value-param, and the pressed one is aria-pressed.
//
// The query and the pressed options live in the markup, so connect reads them.
// Bind reset to turbo:before-cache@document so a restored page starts
// unfiltered.
export default class extends Controller {
  static targets = [ "search", "count", "option" ]
  static values = { selector: String, noun: String }
  static classes = [ "active", "inactive" ]

  connect() {
    this.apply()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  // The search waits for 300 ms of quiet before it filters.
  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.apply(), 300)
  }

  choose({ params: { key, value } }) {
    this.press(key, value)
    this.apply()
  }

  reset() {
    clearTimeout(this.timer)
    if (this.hasSearchTarget) this.searchTarget.value = ""
    new Set(this.optionTargets.map((option) => option.dataset.cardFilterKeyParam)).forEach((key) => this.press(key, "all"))
    this.apply()
  }

  press(key, value) {
    this.optionTargets
      .filter((option) => option.dataset.cardFilterKeyParam === key)
      .forEach((option) => {
        const pressed = option.dataset.cardFilterValueParam === String(value)
        option.setAttribute("aria-pressed", String(pressed))
        option.classList.remove(...(pressed ? this.inactiveClasses : this.activeClasses))
        option.classList.add(...(pressed ? this.activeClasses : this.inactiveClasses))
      })
  }

  get filters() {
    const filters = {}
    this.optionTargets
      .filter((option) => option.getAttribute("aria-pressed") === "true")
      .forEach((option) => { filters[option.dataset.cardFilterKeyParam] = option.dataset.cardFilterValueParam })
    return filters
  }

  apply() {
    const query = this.hasSearchTarget ? this.searchTarget.value : ""
    const filters = this.filters
    let count = 0
    this.element.querySelectorAll(this.selectorValue).forEach((card) => {
      const visible = cardVisible({ text: card.dataset.name, values: card.dataset }, query, filters)
      card.hidden = !visible
      if (visible) count += 1
    })
    if (this.hasCountTarget) this.countTarget.textContent = countLabel(count, this.nounValue)
  }
}
