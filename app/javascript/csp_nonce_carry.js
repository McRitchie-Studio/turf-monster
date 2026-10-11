// Carries this document's CSP nonce onto the scripts a Turbo visit, frame or
// stream brings in (turf/csp_nonce says why). Captured once, as the document
// loads; a full load starts a new document and a new capture.
import { carryNonce, documentNonce } from "turf/csp_nonce"

const nonce = documentNonce(document.querySelector('meta[name="csp-nonce"]'))

if (nonce) {
  document.addEventListener("turbo:before-render", (event) => carryNonce(event.detail.newBody, nonce))
  document.addEventListener("turbo:before-frame-render", (event) => carryNonce(event.detail.newFrame, nonce))
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.detail.newStream
    carryNonce(stream && stream.templateContent, nonce)
  })
}
