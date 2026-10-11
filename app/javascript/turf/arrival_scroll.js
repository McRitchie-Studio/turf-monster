// The rule behind the arrival-scroll controller. No DOM.

// How long after arrival the page scrolls, in milliseconds.
export const SCROLL_DELAY_MS = 200

// Where a contest page scrolls on arrival, from its query string:
// ?scroll=<px> scrolls to that offset; ?add_entry=true or ?edit_entry=<slug>
// brings the board into view; anything else stays put.
export function arrivalScroll(search) {
  const params = new URLSearchParams(search)
  const px = parseInt(params.get("scroll"), 10)
  if (px > 0) return { top: px }
  if (params.get("add_entry") === "true" || params.get("edit_entry")) return { board: true }
  return null
}
