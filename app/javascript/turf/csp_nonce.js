// The rule behind csp_nonce_carry. No DOM beyond the root it is handed.
//
// A browser applies the script policy of the document it loaded, and its
// nonce is the one that document's header named. A Turbo visit keeps that
// document, but the new page carries the nonce of its own request, so a
// script Turbo runs from it is refused by a strict policy. Turbo already
// gives every script it runs the csp-nonce meta's value; the new page then
// overwrites it with its own nonce attribute. Carrying the document's nonce
// onto every script in the incoming content keeps them runnable, and trusts
// what Turbo already trusts: same-origin HTML it fetched.

// The document's nonce: the csp-nonce meta's content as the page loaded.
export function documentNonce(meta) {
  const nonce = meta && meta.content
  return nonce ? nonce : null
}

// Sets the nonce on every script under root; returns how many.
export function carryNonce(root, nonce) {
  if (!root || !nonce) return 0
  const scripts = root.querySelectorAll("script")
  scripts.forEach((script) => script.setAttribute("nonce", nonce))
  return scripts.length
}
