import { Controller } from "@hotwired/stimulus"

// Wipes the browser's client state as a Log out link is followed (the
// session_wipe module defines window.wipeClientState). Replaces an inline
// onclick, which a signing page's script policy refuses. The link navigates
// either way, so a press before this connects still logs out.
export default class extends Controller {
  wipe() {
    if (window.wipeClientState) window.wipeClientState()
  }
}
