import { Controller } from "@hotwired/stimulus"
import { noticeFor } from "turf/desktop_only_notice"

// On a phone, shows the desktop-only notice in window.walletProvider's own
// words and disables every [data-desktop-only-action] button on the page:
// disabled, not hidden, so the operator still sees they reached the right
// page. A press that slips through still meets the provider's own refusal.
// Rendered hidden; a desktop sees nothing.
export default class extends Controller {
  static targets = [ "message" ]

  connect() {
    const { show, message } = noticeFor(window.walletProvider)
    if (!show) return
    if (message !== null && this.hasMessageTarget) this.messageTarget.textContent = message
    this.element.hidden = false
    document.querySelectorAll("[data-desktop-only-action]").forEach((button) => { button.disabled = true })
  }
}
