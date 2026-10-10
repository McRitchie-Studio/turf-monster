import { Controller } from "@hotwired/stimulus"

// Submits its form once, the moment it connects, so a person's one click on an
// emailed link is the whole act. A scanner that runs no script submits nothing,
// and the form's own button is the fallback. The data-auto-submitted mark keeps
// a page restored from history from submitting again.
export default class extends Controller {
  connect() {
    const form = this.element
    if (form.dataset.autoSubmitted) return
    form.dataset.autoSubmitted = "1"
    if (typeof form.requestSubmit === "function") form.requestSubmit(); else form.submit()
  }
}
