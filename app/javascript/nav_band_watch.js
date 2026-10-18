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
// thing in it. So the rows ([data-turf-nav-column]) are observed as well, and a
// change in either one asks for the re-measure.
let observer = null

function watch() {
  if (observer) observer.disconnect()
  observer = null
  const header = document.querySelector("header[data-nav-timeline]")
  const column = header && header.querySelector(".user-nav-col")
  if (!column || typeof ResizeObserver !== "function") return
  const watched = [column, column.querySelector("[data-turf-nav-column]")].filter(Boolean)

  const last = new Map()
  observer = new ResizeObserver((entries) => {
    let changed = false
    entries.forEach(({ target }) => {
      const height = target.offsetHeight
      if (last.has(target) && last.get(target) !== height) changed = true
      last.set(target, height)
    })
    if (changed && header.hasAttribute("data-nav-timeline-on")) window.dispatchEvent(new Event("resize"))
  })
  watched.forEach((el) => observer.observe(el))
}

document.addEventListener("turbo:load", watch)
