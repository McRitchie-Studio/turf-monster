// THE TIMELINE BAND FOLLOWS THE ACCOUNT COLUMN (/tasks/turf-engine-navbar-timeline).
//
// On the scroll-timeline header (studio-engine 0.111.1, Studio.navbar_scroll_timeline)
// the nav-collapse controller measures the band, the header's height expanded
// less collapsed, on connect, a window resize, a font load and a bar resize,
// and never again. This header's account column changes height AFTER connect:
// the balance renders hidden on a cold cache and refreshBalance() reveals it
// about 400ms later, which grows the collapsed bar by 2px (measured at 1440:
// collapsed 48 -> 50 while --nav-band stayed 48). The compact bar then shows
// 2px less than it needs and its row sits a pixel off centre.
//
// So when the column's size changes on a timeline header, this asks the
// controller to measure again through the one door it listens on, a window
// resize. It fires on a hydrate or a balance-face swap, never per scroll
// frame: nothing in the column moves with the scroll on the timeline.
//
// IT WATCHES THE ACCOUNT COLUMN'S TWO ROWS, NOT ONLY THE COLUMN'S BOX
// (/tasks/turf-navbar-avatar-table-header). From 768px the avatar is 40px at
// rest, taller than the two rows beside it, so the hydrate that grows the rows
// by 2px no longer grows the column: the avatar holds its height. The COLLAPSED
// bar still grows, because there the avatar is 32px and the rows are the tallest
// thing in it. So the rows (inside the engine user nav's [data-nav-tools]) are observed too, and a
// change in either one asks for the re-measure.
//
// IT WATCHES THE LOGO LINK'S WIDTH TOO (/tasks/turf-nav-links-follow). From
// studio-engine 0.111.3 the same measure publishes --nav-brand-shrink, the width
// the logo link gives up when it scales, and the desktop links ([data-nav-links])
// slide left by it so their gap to the wordmark holds. The logo link is min-w-0,
// so it is the flex item that gives way when the row runs short: at 768px the
// links end 26.8px short of their column (measured signed in and out), and a geo
// badge or wallet signal that hydrates wider than that narrows the logo link
// with no window resize. A stale --nav-brand-shrink would then open or close the
// gap as the page scrolls. Its width is layout, not paint: the scroll-driven
// scale is a transform, so this never fires per scroll frame.
//
// THE FIRST DELIVERY IS A READING, NOT A BASELINE (/tasks/turf-flaky-tests-steady).
// The controller measures when it starts, at connect; this watcher begins at
// turbo:load, and a ResizeObserver reports each element once, on the first
// frame after observe(). Seeding the last sizes from that first report
// swallowed any change that landed before it: a balance or seeds row that
// hydrated between the controller's measure and that frame (a long task after
// load is enough) became the baseline, nothing asked for a re-measure, and
// --nav-band stayed 2px short of the header's collapse for good (CI run
// 40789678684, 1280px; with Studio.navbar_name_in_rows the name and the
// balance share row 1, so row 1 is the one that moves). So the sizes are read
// when observe() is called, and the first report compares against them; and
// because a change can also land before this watcher starts (between connect
// and turbo:load), the first report checks the band itself against the
// header's own collapse and asks for a re-measure when they disagree.
let observer = null

// The header's own collapse: its height at rest less its height with the
// collapse forced, the same reading the controller publishes as --nav-band.
// The two writes cancel inside one task, so no frame ever paints them.
function bandIsStale(header) {
  const band = parseFloat(header.style.getPropertyValue("--nav-band"))
  if (!Number.isFinite(band)) return false
  const prior = header.style.getPropertyValue("--nav-p")
  header.style.removeProperty("--nav-p")
  const rest = header.offsetHeight
  header.style.setProperty("--nav-p", "1")
  const collapsed = header.offsetHeight
  if (prior) header.style.setProperty("--nav-p", prior)
  else header.style.removeProperty("--nav-p")
  return Math.abs(band - (rest - collapsed)) > 0.5
}

function watch() {
  if (observer) observer.disconnect()
  observer = null
  const header = document.querySelector("header[data-nav-timeline]")
  const column = header && header.querySelector(".user-nav-col")
  if (!column || typeof ResizeObserver !== "function") return
  const brand = header.querySelector(".nav-logo-link")
  // The ROWS inside the engine's icon column, not the column: [data-nav-tools]
  // is a flex item the row STRETCHES to the 40px avatar at rest, so its own box
  // never moves when the balance reveals itself, while the compact bar (32px
  // avatar) still grows 32 -> 34 with it. Measured on /tasks/turf-readopts-engine-navbar:
  // watching the column left --nav-band 2px stale; its rows report the change.
  const rows = Array.from(column.querySelectorAll("[data-nav-tools] > *"))
  const watched = [column, ...rows, brand].filter(Boolean)
  // The column's rows change the band by their height; the logo link changes
  // --nav-brand-shrink by its width.
  const size = (el) => (el === brand ? el.offsetWidth : el.offsetHeight)

  const last = new Map(watched.map((el) => [el, size(el)]))
  let first = true
  observer = new ResizeObserver((entries) => {
    let changed = false
    entries.forEach(({ target }) => {
      const value = size(target)
      if (last.get(target) !== value) changed = true
      last.set(target, value)
    })
    const on = header.hasAttribute("data-nav-timeline-on")
    if (first && on && !changed) changed = bandIsStale(header)
    if (on) first = false
    if (changed && on) window.dispatchEvent(new Event("resize"))
  })
  watched.forEach((el) => observer.observe(el))
}

document.addEventListener("turbo:load", watch)
