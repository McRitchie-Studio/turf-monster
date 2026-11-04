// Keeps a signing page its own document (turf/signing_document says why).
// Read once, as the document loads: a full load starts a new document.
import { SIGNING_DOCUMENT_HEADER, dropTemporary, isStrictDocument, leaveWithoutPicture, stripScripts } from "turf/signing_document"

if (isStrictDocument(document.querySelector('meta[name="signing-csp"]'))) {
  // Leave by a full load, so the strict policy never governs another page.
  document.addEventListener("turbo:before-visit", (event) => {
    event.preventDefault()
    window.location.assign(event.detail.url)
  })
  // Every Turbo fetch says it came from a strict document. A form's redirect
  // is followed inside that fetch and then left by the full load above, so
  // the page it lands on is rendered twice; SigningCsp keeps the flash for the
  // second. The header rides the followed redirect (same origin).
  document.addEventListener("turbo:before-fetch-request", (event) => {
    const headers = event.detail.fetchOptions && event.detail.fetchOptions.headers
    if (headers) headers[SIGNING_DOCUMENT_HEADER] = "strict"
  })
  // What Turbo would leave out of a snapshot stays out of the back/forward cache.
  window.addEventListener("pageswap", (event) => leaveWithoutPicture(document, event.viewTransition))
  window.addEventListener("pagehide", () => dropTemporary(document))
  // A key page came back from the cache with its key dropped: load it again.
  window.addEventListener("pageshow", (event) => {
    if (event.persisted && document.querySelector("[data-no-leaving-picture]")) window.location.reload()
  })
  document.addEventListener("turbo:before-frame-render", (event) => stripScripts(event.detail.newFrame))
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.detail.newStream
    if (stream && stream.firstElementChild instanceof HTMLTemplateElement) stripScripts(stream.firstElementChild.content)
  })
}
