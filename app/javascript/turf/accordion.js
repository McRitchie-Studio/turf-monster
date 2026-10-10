// The rule behind the accordion controller. No DOM.

// The section open after a press on `key`: pressing the open one closes it,
// pressing another opens that one alone.
export function toggled(open, key) {
  return open === key ? null : key
}
