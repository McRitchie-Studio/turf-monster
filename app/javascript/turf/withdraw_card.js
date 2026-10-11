// The rules behind the withdraw-card controller. No DOM.

// The card opens itself when the page is reached at #cash-out, unless the
// account is frozen (its Withdraw button is disabled then).
export function openAtStart({ hash, frozen }) {
  return !frozen && hash === "#cash-out"
}

// The submit waits for both fields.
export function canSubmit(amount, destination) {
  return !!amount && !!destination
}

export function toggleLabel(open) {
  return open ? "Cancel" : "Withdraw"
}
