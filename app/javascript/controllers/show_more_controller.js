import { Controller } from "@hotwired/stimulus"

// Reveals the rest of a list: the extra items, and the label that names the
// next press.
//
// The markup is the state: collapsed is the extra items and the "less" label
// hidden. Bind collapse to turbo:before-cache@document so a restored page
// starts collapsed.
export default class extends Controller {
  static targets = [ "extra", "more", "less" ]

  toggle() {
    this.render(!this.expanded)
  }

  collapse() {
    this.render(false)
  }

  get expanded() {
    return this.hasMoreTarget && this.moreTarget.hidden
  }

  render(expanded) {
    this.extraTargets.forEach((item) => { item.hidden = !expanded })
    this.moreTargets.forEach((label) => { label.hidden = expanded })
    this.lessTargets.forEach((label) => { label.hidden = !expanded })
  }
}
