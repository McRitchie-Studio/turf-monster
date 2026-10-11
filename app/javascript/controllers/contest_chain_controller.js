import { Controller } from "@hotwired/stimulus"

// An admin's on-chain contest actions: Lock and Conclude, now or after a
// delay, each signed in the admin's own wallet by lock_contest.js. This only
// presses it, passing the same contest slug and delay in seconds.
export default class extends Controller {
  static values = { slug: String }

  lock({ params: { delay } }) {
    window.lockContestViaPhantom(this.slugValue, delay)
  }

  conclude({ params: { delay } }) {
    window.concludeContestViaPhantom(this.slugValue, delay)
  }
}
