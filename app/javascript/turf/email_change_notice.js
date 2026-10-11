// The rule behind the email-change-notice controller. No DOM.

// Whether the address typed differs from the one on the account, ignoring case:
// only then does the change wait on a link sent to the current address.
export function emailChanged(initial, current) {
  return String(current || "").toLowerCase() !== String(initial || "").toLowerCase()
}
