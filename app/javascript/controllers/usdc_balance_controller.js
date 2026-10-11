import { Controller } from "@hotwired/stimulus"
import { balanceText } from "turf/usdc_balance"

// The wallet page's balance: the server renders its figure, and connect asks
// `url` for a fresher one, keeping the figure when the answer has none.
export default class extends Controller {
  static targets = [ "amount" ]
  static values = { url: String }

  connect() {
    fetch(this.urlValue).then((response) => response.json()).then((data) => {
      const text = balanceText(data)
      if (text !== null && this.hasAmountTarget) this.amountTarget.textContent = text
    })
  }
}
