import { Controller } from "@hotwired/stimulus"
import { RESIZE_DEBOUNCE_MS, gridRow, layout, pillLayout } from "turf/leaderboard"

// The leaderboard list. Its pills key off this column's own width
// (turf/leaderboard): one row of six at 600px and up, a 3x2 grid at 450px and
// up, the compressed fan below that, which a press on the row opens. Past eight
// seats the tail folds behind "Show all".
//
// Targets: each entry's `picks` wrapper holds a `narrow` and a `full` layout;
// each narrow `pill` carries data-index and data-count, and its multiplier is a
// `value`. Folded rows (and a folded money line) are `tail`; `more` and `less`
// are the fold's two controls.
//
// The width lives in the controller: connect measures it and draws, so both
// layouts are hidden in the markup until then. The fold and each row's press
// live in the markup (the tail's `hidden`, the wrapper's data-open). Bind reset
// to turbo:before-cache@document so a restored page starts folded and closed;
// disconnect clears the timers.
export default class extends Controller {
  static targets = [ "picks", "narrow", "full", "pill", "value", "tail", "more", "less" ]

  connect() {
    this.measure()
    this.frame = requestAnimationFrame(() => this.measure())
  }

  disconnect() {
    cancelAnimationFrame(this.frame)
    clearTimeout(this.timer)
  }

  resized() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.measure(), RESIZE_DEBOUNCE_MS)
  }

  measure() {
    this.size = layout(this.element.clientWidth)
    this.draw()
  }

  expand() {
    this.fold(false)
  }

  collapse() {
    this.fold(true)
  }

  togglePicks(event) {
    const picks = event.currentTarget.closest("[data-leaderboard-target~='picks']")
    picks.dataset.open = picks.dataset.open === "true" ? "false" : "true"
    this.draw()
  }

  reset() {
    this.fold(true)
    this.picksTargets.forEach((picks) => { picks.dataset.open = "false" })
    this.draw()
  }

  fold(folded) {
    this.tailTargets.forEach((row) => { row.hidden = folded })
    this.moreTargets.forEach((el) => { el.hidden = !folded })
    this.lessTargets.forEach((el) => { el.hidden = folded })
  }

  draw() {
    if (!this.size) return
    const { wide, mid, dkFull } = this.size
    this.picksTargets.forEach((picks) => {
      const open = picks.dataset.open === "true"
      const grid = gridRow({ open, wide })
      const within = (name) => picks.querySelectorAll(`[data-leaderboard-target~="${name}"]`)
      within("narrow").forEach((narrow) => {
        narrow.hidden = dkFull
        const row = narrow.firstElementChild
        if (!row) return
        row.classList.toggle("grid", grid)
        row.classList.toggle("grid-cols-3", grid)
        row.classList.toggle("gap-1.5", grid)
        row.classList.toggle("flex", !grid)
      })
      within("full").forEach((full) => { full.hidden = !dkFull })
      within("value").forEach((value) => { value.hidden = !grid })
      within("pill").forEach((pill) => {
        const { classes, style } = pillLayout({
          index: Number(pill.dataset.index), count: Number(pill.dataset.count), open, wide, mid
        })
        Object.entries(classes).forEach(([ name, on ]) => pill.classList.toggle(name, on))
        Object.entries(style).forEach(([ property, value ]) => { pill.style[property] = value === null ? "" : value })
      })
    })
  }
}
