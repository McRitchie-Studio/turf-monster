// The rule behind the send-gate controller. No DOM.

// Whether Send stays disabled: nobody to send to, a typed count that is not
// the recipient count, or a send before the drop without "Send early".
export function sendBlocked({ count, typed, needsEarly, early }) {
  if (count === 0) return true
  if (String(typed).trim() !== String(count)) return true
  return Boolean(needsEarly) && !early
}
