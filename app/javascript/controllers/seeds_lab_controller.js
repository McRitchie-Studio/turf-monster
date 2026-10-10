import { Controller } from "@hotwired/stimulus"
import {
  initialState, add, jumpTo, reset, levelUpSteps, shine, labels, styles, sprout, sectionFill
} from "turf/seeds_lab"

const SHINE_REMOUNT_MS = 30

// The seeds loader lab: one simulated seed total drawn by every variant on the
// page, and the shine controls of variant 1.
export default class extends Controller {
  static targets = [
    "label", "styled", "simButton", "pop", "shimmer", "sprout", "sectionFill",
    "mode", "interval", "delay", "pulseOnly"
  ]

  // Starts from zero, whatever a restored page left on screen.
  connect() {
    this.timers = []
    this.state = initialState()
    this.modeTarget.value = this.state.shineMode
    this.intervalTarget.value = this.state.shineInterval
    this.delayTarget.value = this.state.shineDelay
    this.render()
  }

  disconnect() {
    this.timers.forEach((timer) => clearTimeout(timer))
    this.timers = []
  }

  add(event) {
    const { state, levelUp } = add(this.state, event.params.amount)
    this.state = state
    if (levelUp) this.runLevelUp(levelUp)
    this.render()
  }

  jump(event) {
    this.state = jumpTo(this.state, event.params.to)
    this.render()
  }

  reset() {
    this.state = reset(this.state)
    this.render()
  }

  shineChanged() {
    this.change({
      shineMode: this.modeTarget.value,
      shineInterval: Number(this.intervalTarget.value),
      shineDelay: Number(this.delayTarget.value)
    })
  }

  // Hides the shimmer for a moment, which restarts its animation.
  triggerShine() {
    this.change({ shineVisible: false })
    this.later(SHINE_REMOUNT_MS, () => this.change({ shineVisible: true }))
  }

  runLevelUp(newLevel) {
    levelUpSteps(newLevel, this.state.seeds).forEach(({ at, change }) => {
      at === 0 ? this.change(change) : this.later(at, () => this.change(change))
    })
  }

  change(change) {
    this.state = { ...this.state, ...change }
    this.render()
  }

  later(ms, run) {
    this.timers.push(setTimeout(run, ms))
  }

  render() {
    const state = this.state
    const text = labels(state)
    const css = styles(state)
    const { shown, ...animation } = shine(state)

    this.labelTargets.forEach((element) => { element.textContent = text[element.dataset.label] })
    this.styledTargets.forEach((element) => {
      Object.entries(css[element.dataset.style]).forEach(([ name, value ]) => element.style.setProperty(name, value))
    })
    this.simButtonTargets.forEach((button) => { button.disabled = state.levelingUp })
    this.popTargets.forEach((element) => element.classList.toggle("level-up-pop", state.levelingUp))
    this.shimmerTargets.forEach((element) => {
      Object.assign(element.style, animation)
      element.hidden = !shown
    })
    this.sproutTargets.forEach((element) => {
      const { text: glyph, transform, filter } = sprout(state.displaySeeds, Number(element.dataset.index))
      element.textContent = glyph
      Object.assign(element.style, { transform, filter })
    })
    this.sectionFillTargets.forEach((element) => {
      element.style.width = sectionFill(state.displaySeeds, Number(element.dataset.index)) + "%"
    })
    this.pulseOnlyTargets.forEach((element) => { element.hidden = state.shineMode !== "pulse" })
  }
}
