import { Controller } from "@hotwired/stimulus"
import { demoSteps } from "turf/toast_demos"

// The toast test page's buttons: each fires the engine's `toast` window event,
// once with the detail it carries, or as a scripted demo.
export default class extends Controller {
  connect() {
    this.timers = []
  }

  disconnect() {
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers = []
  }

  fire(event) {
    this.toast(event.params.detail)
  }

  demo(event) {
    demoSteps(event.params.name).forEach(({ at, detail }) => {
      at === 0 ? this.toast(detail) : this.timers.push(setTimeout(() => this.toast(detail), at))
    })
  }

  // A button's `then` becomes the press handler the toast host calls.
  toast({ buttons, ...detail }) {
    if (buttons) {
      detail.buttons = buttons.map(({ then, ...button }) => {
        if (then) button.onclick = () => this.toast(then)
        return button
      })
    }
    window.dispatchEvent(new CustomEvent("toast", { detail }))
  }
}
