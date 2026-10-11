import { Controller } from "@hotwired/stimulus"
import { COPIED_MS, closesPopover, copyButtonClasses } from "turf/referral_share"
import { enter, leave, settle } from "turf/enter_leave"

// The referral card: a link to copy, and an info popover. Copy writes `url` to
// the clipboard and the button says "Copied!" for COPIED_MS. The popover opens
// from its toggle, and closes on its close button, on Escape and on a click
// outside it; it fades with the classes in its data-enter* and data-leave*
// attributes.
//
// The markup is the state: popover hidden, button at rest. Bind reset to
// turbo:before-cache@document so a restored page starts so; disconnect clears
// the timers.
export default class extends Controller {
  static targets = [ "popover", "toggle", "button", "copyLabel", "copiedLabel" ]
  static values = { url: String }

  connect() {
    this.timers = new Set()
    this.infoOpen = !this.popoverTarget.hidden
  }

  disconnect() {
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers.clear()
  }

  copy() {
    navigator.clipboard.writeText(this.urlValue)
    this.renderCopied(true)
    const timer = setTimeout(() => {
      this.timers.delete(timer)
      this.renderCopied(false)
    }, COPIED_MS)
    this.timers.add(timer)
  }

  toggleInfo() {
    if (this.infoOpen) {
      this.closeInfo()
    } else {
      this.infoOpen = true
      enter(this.popoverTarget)
    }
  }

  closeInfo() {
    if (!this.infoOpen) return
    this.infoOpen = false
    leave(this.popoverTarget)
  }

  outside(event) {
    const insidePopover = this.popoverTarget.contains(event.target)
    const onToggle = this.hasToggleTarget && this.toggleTarget.contains(event.target)
    if (closesPopover({ open: this.infoOpen, insidePopover, onToggle })) this.closeInfo()
  }

  reset() {
    this.disconnect()
    this.renderCopied(false)
    this.infoOpen = false
    settle(this.popoverTarget, false)
  }

  renderCopied(copied) {
    const { add, remove } = copyButtonClasses(copied)
    this.buttonTarget.classList.remove(remove)
    this.buttonTarget.classList.add(add)
    this.copyLabelTarget.hidden = copied
    this.copiedLabelTarget.hidden = !copied
  }
}
