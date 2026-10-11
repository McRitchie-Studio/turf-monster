import { Controller } from "@hotwired/stimulus"
import { emailChanged } from "turf/email_change_notice"

// Says that a new email address waits on a confirmation link, while the field
// holds an address other than `initial`. connect reads the field, so what was
// typed before it connected counts. Rendered hidden; bind reset to
// turbo:before-cache@document so a restored page starts as a fresh one: the
// address on the account, and no notice.
export default class extends Controller {
  static targets = [ "field", "notice" ]
  static values = { initial: String }

  connect() {
    this.check()
  }

  check() {
    if (!this.hasNoticeTarget) return
    this.noticeTarget.hidden = !emailChanged(this.initialValue, this.fieldTarget.value)
  }

  reset() {
    this.fieldTarget.value = this.fieldTarget.defaultValue
    if (this.hasNoticeTarget) this.noticeTarget.hidden = true
  }
}
