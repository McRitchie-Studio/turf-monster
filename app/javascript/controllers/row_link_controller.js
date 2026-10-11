import { Controller } from "@hotwired/stimulus"

// Makes a whole table row a link to its data-row-link-url-param. A press on a
// real link inside the row is that link's own, so it does not fire twice.
export default class extends Controller {
  visit(event) {
    if (event.target.closest("a")) return
    window.location = event.params.url
  }
}
