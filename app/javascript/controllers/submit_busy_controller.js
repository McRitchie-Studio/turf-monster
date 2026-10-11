import { Controller } from "@hotwired/stimulus"
import { IDLE, submitState } from "turf/submit_busy"

// A form that says it is working while Turbo submits it. Bind start to
// turbo:submit-start and end to turbo:submit-end on the form: submit-start
// fires only once a turbo_confirm is accepted, so declining one leaves no
// spinner. Every target is optional:
//
//   idle / busy   the label at rest and the one while submitting
//   button        disabled while submitting
//   throttled     shown when the answer was rack-attack's 429
//   error         the last refusal, hidden while a throttle is shown
//
// The markup is the state: rendered idle. Bind reset to
// turbo:before-cache@document so a restored page starts idle.
export default class extends Controller {
  static targets = [ "idle", "busy", "button", "throttled", "error" ]

  start() {
    this.render(submitState("start"))
  }

  end(event) {
    const status = event.detail && event.detail.fetchResponse ? event.detail.fetchResponse.response.status : undefined
    this.render(submitState("end", status))
  }

  reset() {
    this.render(IDLE)
  }

  render({ busy, throttled }) {
    this.idleTargets.forEach((el) => { el.hidden = busy })
    this.busyTargets.forEach((el) => { el.hidden = !busy })
    this.buttonTargets.forEach((el) => { el.disabled = busy })
    this.throttledTargets.forEach((el) => { el.hidden = !throttled })
    this.errorTargets.forEach((el) => { el.hidden = throttled })
  }
}
