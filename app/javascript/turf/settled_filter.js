// The rule behind the settled-filter controller. No DOM.

// The admin toggle's look for each state.
export function toggleLook(showSettled) {
  return showSettled
    ? { className: "btn btn-secondary", text: "Hide Settled", pressed: "true" }
    : { className: "btn btn-outline", text: "Show Settled", pressed: "false" }
}
