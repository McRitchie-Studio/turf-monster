import { Controller } from "@hotwired/stimulus"
import { POLL_MS, freshList, pollUrl } from "turf/leaderboard_poll"

// Asks every ninety seconds whether the contest's leaderboard changed, and if
// it did, swaps the fresh list into #leaderboard-container and says so with a
// toast. A failed ask is retried at the next tick.
//
// The poll lives in the controller; disconnect stops it.
export default class extends Controller {
  static values = { slug: String, version: Number }

  connect() {
    this.timer = setInterval(() => this.poll(), POLL_MS)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const resp = await fetch(pollUrl(this.slugValue, this.versionValue))
      const fresh = freshList(await resp.json())
      if (!fresh) return
      const container = document.getElementById("leaderboard-container")
      if (!container) return
      container.innerHTML = fresh.html
      this.versionValue = fresh.version
      window.dispatchEvent(new CustomEvent("toast", {
        detail: { type: "info", title: "Leaderboard Updated", message: "Scores have changed", duration: 3000 }
      }))
    } catch (e) { /* retried at the next tick */ }
  }
}
