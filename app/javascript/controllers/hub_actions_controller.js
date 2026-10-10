import { Controller } from "@hotwired/stimulus"
import { showNavSpinner, hideNavSpinner } from "studio/head_chrome"
import { refreshBalance } from "solana_utils"

// The admin hub's two page actions.
export default class extends Controller {
  // Re-reads the signed-in wallet's balance under the navbar spinner.
  refreshBalance() {
    showNavSpinner()
    refreshBalance().finally(() => hideNavSpinner())
  }

  // Asks the navbar's seeds bar to replay its level-up.
  replayLevel(event) {
    event.currentTarget.dispatchEvent(new CustomEvent("navbar-replay-level", {
      detail: {}, bubbles: true, composed: true, cancelable: true
    }))
  }
}
