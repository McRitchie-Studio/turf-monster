// The rules behind the leaderboard controller. No DOM.
//
// The pills key off the leaderboard column's own width, not the window's:
// >= 600px one row of six; >= 450px a 3x2 grid; below that the compressed fan,
// which a press opens into the grid.

export const RESIZE_DEBOUNCE_MS = 100

export function layout(width) {
  return { wide: width >= 450, mid: width >= 450, dkFull: width >= 600 }
}

// Whether a narrow row lays its pills out as the 3x2 grid, with each pill's
// multiplier showing, rather than the fan.
export function gridRow({ open, wide }) {
  return open || wide
}

// One narrow-row pill: the classes it wears and the inline style it adds (a
// null value takes that property off). `open` is the row's own press.
export function pillLayout({ index, count, open, wide, mid }) {
  const last = index === count - 1
  const grid = gridRow({ open, wide })
  const classes = {
    "px-2": open || mid,
    "px-1": !open && !mid,
    "justify-between": last ? grid : true,
    "justify-center": last ? !grid : false
  }
  if (grid) return { classes, style: { width: null, marginLeft: null, position: null, zIndex: null } }

  const width = wide ? "7rem" : (mid ? `calc((100% - ${(count - 1) * 0.3}rem) / ${count})` : "5rem")
  let marginLeft = null
  if (index > 0) {
    marginLeft = wide ? `calc((100% - ${count * 7}rem) / ${count - 1})`
      : (mid ? "0.3rem" : `calc((100% - ${count * 5}rem) / ${count - 1})`)
  }
  return { classes, style: { width, marginLeft, position: "relative", zIndex: String(index + 1) } }
}

