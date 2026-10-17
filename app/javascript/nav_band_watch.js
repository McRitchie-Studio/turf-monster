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
let observer = null

function watch() {
  if (observer) observer.disconnect()
  observer = null
  const header = document.querySelector("header[data-nav-timeline]")
  const column = header && header.querySelector(".user-nav-col")
  if (!column || typeof ResizeObserver !== "function") return

  let last = null
  observer = new ResizeObserver(() => {
    const height = column.offsetHeight
    const changed = last !== null && height !== last
    last = height
    if (changed && header.hasAttribute("data-nav-timeline-on")) window.dispatchEvent(new Event("resize"))
  })
  observer.observe(column)
}

document.addEventListener("turbo:load", watch)
