import { Controller } from "@hotwired/stimulus"
import { previewState } from "turf/navbar_preview"

// One navbar preview on /admin/navbar: its width slider, the device-width
// button, and the Scrolled toggle.
//
// The markup is the state: the slider's value is the width, and the frame's
// is-scrolled-preview class is the toggle. Bind reset to
// turbo:before-cache@document so a restored page starts at the device width.
export default class extends Controller {
  static targets = [ "label", "slider", "toggle", "frame" ]
  static values = { deviceWidth: Number }

  connect() {
    this.render()
  }

  resize() {
    this.render()
  }

  fit() {
    this.sliderTarget.value = this.deviceWidthValue
    this.render()
  }

  toggleScrolled() {
    this.frameTarget.classList.toggle("is-scrolled-preview")
    this.render()
  }

  reset() {
    this.frameTarget.classList.remove("is-scrolled-preview")
    this.fit()
  }

  render() {
    const state = previewState(this.sliderTarget.value, this.frameTarget.classList.contains("is-scrolled-preview"))
    this.labelTarget.textContent = state.label
    this.frameTarget.style.width = state.width
    this.frameTarget.style.setProperty("--nav-p", state.navP)
    this.toggleTarget.classList.remove(...state.remove)
    this.toggleTarget.classList.add(...state.add)
  }
}
