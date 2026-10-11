import { Controller } from "@hotwired/stimulus"

// Tabs that switch which panel shows below md. Each tab names its key with
// data-tabs-key-param and each panel carries data-key. A panel hides with the
// `hidden` class, not the attribute, so its own md:block still wins on a wide
// screen.
//
// The markup is the state: the initial tab active and the other panels hidden.
// Bind reset to turbo:before-cache@document so a restored page starts on the
// initial tab.
export default class extends Controller {
  static targets = [ "tab", "panel" ]
  static values = { initial: String }
  static classes = [ "active", "inactive" ]

  select({ params: { key } }) {
    this.render(key)
  }

  reset() {
    this.render(this.initialValue)
  }

  render(key) {
    this.tabTargets.forEach((tab) => {
      const active = tab.dataset.tabsKeyParam === key
      tab.classList.remove(...(active ? this.inactiveClasses : this.activeClasses))
      tab.classList.add(...(active ? this.activeClasses : this.inactiveClasses))
    })
    this.panelTargets.forEach((panel) => panel.classList.toggle("hidden", panel.dataset.key !== key))
  }
}
