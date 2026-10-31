// THE BRAND FITS OR IT IS THE MASCOT (/tasks/turf-navbar-logo-when-tight).
//
// The navbar draws "Turf Monster" only where it fits whole on ONE line beside
// the mascot and the links; anywhere else it draws the mascot alone, never an
// ellipsis and never a second line (application.css, THE BRAND FITS OR IT IS
// THE MASCOT, which also hides the words for the eye only: they are the page's
// h1).
//
// Only geometry can answer it. The row beside the brand holds the desktop links
// and the nav items, and the wallet chip alone runs from "Managed wallet" to
// "No wallet in this browser"; the geo badge and the chip hydrate after load.
// So this measures each navbar header (the live one and the /admin/navbar
// previews): with the words back in flow and nothing in
// the row allowed to shrink (data-nav-brand-measure), does the row's last item
// still end inside the row? It writes data-nav-brand="fit" or "tight" on the
// header. The measure state is set and cleared inside one task, so no frame
// ever paints it.
//
// THE REST SIZE DECIDES, NOT THE SCROLLED ONE. Below 768px the collapse
// shrinks the type off --nav-p, so the measure pins --nav-p to 0 for its read;
// from 768px the collapse is a transform (the scroll timeline), which offset
// geometry ignores. So the answer never flips while the page scrolls.
//
// IT ANSWERS AT ONCE when this module runs with the document already parsed,
// which on a first load it always is: an importmap module runs after parsing,
// and Turbo, which starts listening for readystatechange only then, misses
// "interactive" and fires its first turbo:load at "complete", after every
// image and font. Waiting for it painted the CSS guess, an ellipsized
// wordmark on a desktop row, for that whole stretch
// (/tasks/turf-navbar-stopgap-cleanup).
//
// IT RE-MEASURES on turbo:load, when the row or any item in it changes size
// (a hydrate, a viewport resize), and when a font loads. Its own write only
// changes the logo link's width, which it does not watch, so it cannot loop;
// nav_band_watch.js does watch that width, and asks the collapse to re-measure.
const MEASURE = "data-nav-brand-measure"
const STATE = "data-nav-brand"
// offsetLeft and offsetWidth are whole pixels, and the renderer ellipses a
// word 0.05px over its box, so a fit has to clear the row by this much.
const SLACK = 1

let fontsHooked = false

// The header's row: the flex that holds the logo link and, from 768px, the
// desktop <nav>. Its last displayed item is what must end inside it.
function parts(header) {
  const link = header.querySelector(".nav-logo-link")
  const row = link && link.parentElement
  if (!row) return null
  const nav = Array.from(row.children).find((el) => el.tagName === "NAV")
  return { link, row, nav }
}

export function brandFits(header) {
  const found = parts(header)
  if (!found) return true
  const { link, row, nav } = found
  const prior = header.style.getPropertyValue("--nav-p")
  header.setAttribute(MEASURE, "")
  header.style.setProperty("--nav-p", "0")
  const last = nav && nav.offsetWidth > 0 ? nav : link
  const end = last.offsetLeft + last.offsetWidth
  const room = row.offsetLeft + row.clientWidth
  header.removeAttribute(MEASURE)
  if (prior) header.style.setProperty("--nav-p", prior)
  else header.style.removeProperty("--nav-p")
  return end + SLACK <= room
}

export function settle(header) {
  const value = brandFits(header) ? "fit" : "tight"
  if (header.getAttribute(STATE) !== value) header.setAttribute(STATE, value)
  return value
}

// Every navbar on the page: the live header, and the /admin/navbar previews,
// which draw the same partial in a fixed-width frame. Geometry is the one
// answer that holds for a frame no media query can see, so the previews get
// it too and show what a phone of that width shows.
function headers() {
  return Array.from(document.querySelectorAll("header.nav-shell[data-navbar-root]"))
}

let observers = []

function watch() {
  observers.forEach((o) => o.disconnect())
  observers = []
  const found = headers().map((header) => [header, parts(header)]).filter(([, p]) => p)
  found.forEach(([header]) => settle(header))
  if (!fontsHooked && document.fonts && document.fonts.addEventListener) {
    fontsHooked = true
    document.fonts.addEventListener("loadingdone", () => headers().forEach((h) => settle(h)))
  }
  if (typeof ResizeObserver !== "function") return
  found.forEach(([header, { row, nav }]) => {
    // The row (a resize, or a preview's slider), the nav itself (a child
    // added or grown) and each of its children (a hydrate inside a child the
    // nav's own box may not show yet).
    const watched = [row, ...(nav ? [nav, ...nav.children] : [])]
    const observer = new ResizeObserver(() => settle(header))
    watched.forEach((el) => observer.observe(el))
    observers.push(observer)
  })
}

document.addEventListener("turbo:load", watch)
if (document.readyState !== "loading") watch()
