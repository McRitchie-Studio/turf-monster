import { Controller } from "@hotwired/stimulus"

// Reveals the rest of a list: the extra items, and the label that names the
// next press.
export default class extends Controller {
  static targets = [ "extra", "more", "less" ]

  // Starts collapsed, whatever a restored page left open.
  connect() {
    this.expanded = false
    this.render()
  }

  toggle() {
    this.expanded = !this.expanded
    this.render()
  }

  render() {
    this.extraTargets.forEach((item) => { item.hidden = !this.expanded })
    this.moreTargets.forEach((label) => { label.hidden = this.expanded })
    this.lessTargets.forEach((label) => { label.hidden = !this.expanded })
  }
}
