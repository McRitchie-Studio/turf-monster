import { Controller } from "@hotwired/stimulus"

// The Co-sign button on the treasury queue (admin/pending_transactions). The
// cosign module defines window.cosignTransaction and
// window.collectExtraCosigners; this replaces the inline onclick, which a
// signing page's script policy refuses. The button's data-tx-slug and
// data-tx-label name the row.
export default class extends Controller {
  cosign() {
    if (!window.cosignTransaction) return
    const button = this.element
    window.cosignTransaction(button.dataset.txSlug, button.dataset.txLabel, window.collectExtraCosigners(button), button)
  }
}
