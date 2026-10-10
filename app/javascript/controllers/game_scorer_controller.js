import { Controller } from "@hotwired/stimulus"
import {
  done, scoreLine, statusLabel, completeLabel, minuteValue,
  addGoalRequest, removeGoalRequest, completeRequest, applyResponse
} from "turf/scoring"

const CONFIRM_FINAL = "Mark this game FINAL? This freezes its scoring and fires the FINAL toast on the live page."

// One fixture on the goal console: records and removes goals and marks the
// game final, then redraws the card from the game the server answers with.
//
// The game lives here, so connect draws it from the value the page rendered.
// It writes data-done on its element and dispatches game-scorer:changed, which
// the toolbar's scoring-filter reads. Bind reset to turbo:before-cache@document
// so a restored page starts with an empty minute field.
export default class extends Controller {
  static targets = [ "score", "status", "minute", "control", "goals", "goalTemplate", "error", "complete" ]
  static values = { game: Object }
  static classes = [ "final", "open" ]

  connect() {
    this.game = this.gameValue
    this.busy = false
    this.error = ""
    this.render()
  }

  addGoal(event) {
    this.send(addGoalRequest(this.game, event.params.side, minuteValue(this.minuteTarget.value)))
    this.minuteTarget.value = ""
  }

  removeGoal(event) {
    this.send(removeGoalRequest(this.game, event.params.id))
  }

  complete() {
    if (!window.confirm(CONFIRM_FINAL)) return
    this.send(completeRequest(this.game))
  }

  reset() {
    this.minuteTarget.value = ""
  }

  async send({ url, method, body }) {
    this.busy = true
    this.error = ""
    this.render()
    try {
      const response = await fetch(url, {
        method,
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
        },
        body: body ? JSON.stringify(body) : undefined
      })
      this.game = applyResponse(this.game, await response.json())
    } catch (error) {
      this.error = error.message
    } finally {
      this.busy = false
      this.render()
    }
  }

  render() {
    const game = this.game
    const finished = done(game)

    this.scoreTarget.textContent = scoreLine(game)
    this.statusTarget.textContent = statusLabel(game)
    this.finalClasses.forEach((name) => this.statusTarget.classList.toggle(name, finished))
    this.openClasses.forEach((name) => this.statusTarget.classList.toggle(name, !finished))
    this.errorTarget.textContent = this.error
    this.completeTarget.textContent = completeLabel(game)
    this.completeTarget.disabled = this.busy || finished

    this.goalsTarget.replaceChildren(...game.goals.map((goal) => this.goalPill(goal)))
    this.goalsTarget.hidden = game.goals.length === 0
    this.controlTargets.forEach((control) => { control.disabled = this.busy })

    this.element.dataset.done = String(finished)
    this.dispatch("changed")
  }

  // One goal's pill, cloned from the card's <template>.
  goalPill(goal) {
    const pill = this.goalTemplateTarget.content.firstElementChild.cloneNode(true)
    pill.querySelector("[data-goal-emoji]").textContent = goal.teamEmoji ?? ""
    pill.querySelector("[data-goal-minute]").textContent = goal.minute ?? ""
    pill.querySelector("[data-goal-tick]").hidden = !goal.minute
    pill.querySelector("[data-goal-remove]").setAttribute("data-game-scorer-id-param", goal.id)
    return pill
  }
}
