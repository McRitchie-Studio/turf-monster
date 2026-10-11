// The rule behind the reveal controller: a trigger that gives way to the region
// it reveals. No DOM.

// Which of the two is hidden when the region is (or is not) open.
export function revealState(open) {
  return { triggerHidden: open, regionHidden: !open }
}
