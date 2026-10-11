import { Controller } from "@hotwired/stimulus"

// The vault init and pause/unpause consoles (admin/vault_init,
// admin/vault_state). Their pages' scripts define window.initVault and
// window.vaultAction; this replaces the inline onclick and the forms'
// onsubmit="return false", which a signing page's script policy refuses.
export default class extends Controller {
  // The forms are inputs for the button, never submitted.
  hold(event) {
    event.preventDefault()
  }

  init() {
    if (window.initVault) window.initVault()
  }

  act(event) {
    if (window.vaultAction) window.vaultAction(event.params.instruction)
  }
}
