import { Controller } from "@hotwired/stimulus"

// The contest chat's message buttons: Hide, the quick reactions, the
// reaction pills, "+" and the full picker. The chat panel's own script
// (contests/_chat_panel) defines the functions these call; this replaces
// the inline onclick attributes, which a signing page's script policy
// refuses. One controller on the panel root reaches every message,
// including those a broadcast appends later.
export default class extends Controller {
  hide(event) {
    if (window.hideChatMessage) window.hideChatMessage(event.currentTarget)
  }

  react(event) {
    if (window.reactToMessage) window.reactToMessage(event.currentTarget, event.params.emoji)
  }

  openPicker(event) {
    if (window.openReactionPicker) window.openReactionPicker(event.currentTarget)
  }

  pick(event) {
    if (window.pickReaction) window.pickReaction(event.params.emoji)
  }
}
