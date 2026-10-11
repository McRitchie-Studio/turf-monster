// The rule behind signing_document. No DOM beyond what it is handed.
//
// A signing page (SigningCsp) is its own document: the strict script policy
// is the one the browser read from that page's header, and a Turbo visit
// would keep it for a page it was never sent with, or keep another page's
// policy for a signing page. So a strict document is entered by a full load
// (turbo-visit-control reload) and left by one, and it runs no script that
// arrives after load: a frame or a stream brings markup, never a program.

// True when the page carries the signing-csp marker.
export function isStrictDocument(meta) {
  return !!meta && meta.content === "strict"
}

// Removes every script under root; returns how many.
export function stripScripts(root) {
  if (!root) return 0
  const scripts = Array.from(root.querySelectorAll("script"))
  scripts.forEach((script) => script.remove())
  return scripts.length
}
