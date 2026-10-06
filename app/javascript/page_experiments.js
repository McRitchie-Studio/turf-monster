// Page A/B test beacons (PageExperiment; ExperimentEventsController).
//
// A page in an experiment marks its root with data-experiment, data-variant
// and, for a visitor who is counted (never a bot), data-experiment-beacon (the
// endpoint). This module then sends:
//   - `visit` on each page load (turbo:load): the server also counts a visit
//     on render when the visitor cookie came back, and the unique index folds
//     the two, so this one only matters for a visitor's very first request;
//   - `<cta>` when an element with data-cta="<name>" is clicked, or a form
//     with data-cta-submit="<name>" is submitted.
//
// FIRE AND FORGET: navigator.sendBeacon queues the POST and returns at once,
// so a tap on a link navigates exactly as it would without this, and the
// request survives the page unloading. The server dedupes per visitor per
// event per day, so a double tap costs nothing.
//
// The body names only the experiment and the event (the server reads the
// variant from the visitor's own cookie) plus the CSRF token, in the form
// body because sendBeacon cannot set a header.
//
// One document listener for the app's lifetime (guarded), reading whichever
// page is current at the moment of the tap.
function experimentRoot() {
  return document.querySelector("[data-experiment][data-experiment-beacon]");
}

function sendExperimentEvent(event) {
  const root = experimentRoot();
  if (!root || !navigator.sendBeacon) return false;
  const body = new FormData();
  body.append("experiment", root.dataset.experiment);
  body.append("event", event);
  const token = document.querySelector("meta[name=csrf-token]");
  if (token) body.append("authenticity_token", token.content);
  try {
    return navigator.sendBeacon(root.dataset.experimentBeacon, body);
  } catch (_e) {
    return false;
  }
}

if (!window.__pageExperimentsBound) {
  window.__pageExperimentsBound = true;
  window.sendExperimentEvent = sendExperimentEvent;

  document.addEventListener("turbo:load", () => sendExperimentEvent("visit"));
  // In case the first turbo:load already fired before this module ran; a
  // second send the same day is folded by the server.
  if (document.readyState === "complete") sendExperimentEvent("visit");

  // Capture phase: a handler that stops propagation (Alpine's .prevent does
  // not, but a future one might) cannot hide the tap from the count.
  document.addEventListener("click", (e) => {
    const cta = e.target.closest && e.target.closest("[data-cta]");
    if (cta) sendExperimentEvent(cta.dataset.cta);
  }, true);

  document.addEventListener("submit", (e) => {
    const name = e.target.dataset && e.target.dataset.ctaSubmit;
    if (name) sendExperimentEvent(name);
  }, true);
}
