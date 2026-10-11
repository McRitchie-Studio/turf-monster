// The rule behind the newsletter-state controller. No DOM.

// Whether the player is subscribed, from a newsletter-state-changed event's
// detail. The modals that change it dispatch the event.
export function subscribedFrom(detail) {
  return !!(detail && detail.subscribed)
}
