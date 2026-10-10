import { Controller } from "@hotwired/stimulus"
import { readouts, solPrice } from "turf/cost_calculator"

// The contract page's deploy-cost calculator: prices the measured lamports at
// the SOL price typed into the field.
//
// The price lives in the field, so connect reads it. Bind reset to
// turbo:before-cache@document so a restored page starts at the default price.
export default class extends Controller {
  static targets = [ "price", "output" ]
  static values = { permLamports: Number, floatLamports: Number }

  connect() {
    this.update()
  }

  update() {
    const figures = readouts(
      { permLamports: this.permLamportsValue, floatLamports: this.floatLamportsValue },
      solPrice(this.priceTarget.value)
    )
    this.outputTargets.forEach((output) => { output.textContent = figures[output.dataset.figure] })
  }

  reset() {
    this.priceTarget.value = this.priceTarget.defaultValue
    this.update()
  }
}
