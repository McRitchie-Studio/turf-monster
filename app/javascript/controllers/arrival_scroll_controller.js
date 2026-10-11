import { Controller } from "@hotwired/stimulus"
import { SCROLL_DELAY_MS, arrivalScroll } from "turf/arrival_scroll"

// Scrolls a contest page on arrival, as its query string asks
// (turf/arrival_scroll): to an offset, or to the board.
//
// disconnect clears the pending scroll.
export default class extends Controller {
  connect() {
    const target = arrivalScroll(window.location.search)
    if (!target) return
    this.timer = setTimeout(() => {
      if (target.top) {
        window.scrollTo({ top: target.top, behavior: "smooth" })
      } else {
        const board = document.getElementById("board")
        if (board) board.scrollIntoView({ behavior: "smooth", block: "start" })
      }
    }, SCROLL_DELAY_MS)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
