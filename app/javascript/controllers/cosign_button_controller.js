import { Controller } from "@hotwired/stimulus"

// A Co-sign button: the treasury queue (admin/pending_transactions) and a
// signer eviction (admin/authorities). The cosign module defines
// window.cosignTransaction and window.collectExtraCosigners; this replaces
// the inline onclick, which a signing page's script policy refuses.
//
// The button names its row: data-tx-slug and data-tx-label. An eviction also
// names its own endpoints (data-rebuild-url, data-broadcast-url) and copy
// (data-success-noun, data-back-label), and offers no extra cosigners.
export default class extends Controller {
  cosign() {
    if (!window.cosignTransaction) return
    const button = this.element
    const data = button.dataset
    if (data.rebuildUrl) {
      window.cosignTransaction(data.txSlug, data.txLabel, [], button, {
        rebuildUrl: data.rebuildUrl,
        broadcastUrl: data.broadcastUrl,
        successNoun: data.successNoun,
        backLabel: data.backLabel
      })
    } else {
      window.cosignTransaction(data.txSlug, data.txLabel, window.collectExtraCosigners(button), button)
    }
  }
}
