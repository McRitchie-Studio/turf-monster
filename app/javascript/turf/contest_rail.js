// The rule behind the contest-rail controller. No DOM.

// The fade on the rail's right edge.
export const MASK = "linear-gradient(to right, black 85%, transparent)"

// Whether the rail has more to show to the right. The 1px slack absorbs a
// fractional scrollLeft at the true end.
export function canScrollRight({ scrollWidth, clientWidth, scrollLeft }) {
  return (scrollWidth - clientWidth - scrollLeft) > 1
}
