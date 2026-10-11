import { Controller } from "@hotwired/stimulus"
import { subscribedFrom } from "turf/newsletter_state"

// The newsletter card's two states. The modals that subscribe and unsubscribe
// dispatch newsletter-state-changed on window; bind update to it.
//
// The server renders `subscribed` and hides the other state. Bind reset to
// turbo:before-cache@document so a restored page starts as the server
// rendered it.
export default class extends Controller {
  static targets = [ "subscribed", "unsubscribed" ]
  static values = { subscribed: Boolean }

  update(event) {
    this.render(subscribedFrom(event.detail))
  }

  reset() {
    this.render(this.subscribedValue)
  }

  render(subscribed) {
    this.subscribedTargets.forEach((el) => { el.hidden = !subscribed })
    this.unsubscribedTargets.forEach((el) => { el.hidden = subscribed })
  }
}
