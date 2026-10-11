// Keeps a signing page its own document (turf/signing_document says why).
// Read once, as the document loads: a full load starts a new document.
import { isStrictDocument, stripScripts } from "turf/signing_document"

if (isStrictDocument(document.querySelector('meta[name="signing-csp"]'))) {
  // Leave by a full load, so the strict policy never governs another page.
  document.addEventListener("turbo:before-visit", (event) => {
    event.preventDefault()
    window.location.assign(event.detail.url)
  })
  document.addEventListener("turbo:before-frame-render", (event) => stripScripts(event.detail.newFrame))
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.detail.newStream
    if (stream && stream.firstElementChild instanceof HTMLTemplateElement) stripScripts(stream.firstElementChild.content)
  })
}
