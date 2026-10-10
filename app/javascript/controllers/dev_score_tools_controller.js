import { Controller } from "@hotwired/stimulus"
import { request } from "turf/dev_score_tools"

// The live scoreboard's dev-only injectors: each button POSTs one score, play,
// conclusion or clear for the team picked in the select. Every button is
// disabled while a request is out.
//
// The pick lives in the select, read at each press. Bind reset to
// turbo:before-cache@document so a restored page starts on the first team.
export default class extends Controller {
  static targets = [ "team", "button" ]

  connect() {
    this.busy = false
  }

  record(event) {
    return this.post("record", event.params.type)
  }

  recordPlay(event) {
    return this.post("recordPlay", event.params.kind)
  }

  conclude() {
    return this.post("conclude")
  }

  clear() {
    return this.post("clear")
  }

  reset() {
    this.teamTarget.selectedIndex = 0
    this.setBusy(false)
  }

  async post(tool, param) {
    if (this.busy) return
    const { path, body } = request(tool, this.teamTarget.value, param)
    this.setBusy(true)
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      await fetch(path, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
        body: JSON.stringify(body)
      })
    } finally {
      this.setBusy(false)
    }
  }

  setBusy(busy) {
    this.busy = busy
    this.buttonTargets.forEach((button) => { button.disabled = busy })
  }
}
