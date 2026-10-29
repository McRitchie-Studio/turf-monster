// app/javascript/nav_labels.js: the engine's icon-only theme toggles get a
// name and a pressed state, and the truncating navbar name gets its full text
// as a title (/tasks/turf-navbar-polish).
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const SOURCE = readFileSync(fileURLToPath(new URL("../../app/javascript/nav_labels.js", import.meta.url)), "utf8")

function element(attrs = {}, children = {}) {
  const map = new Map(Object.entries(attrs))
  return {
    attrs: map,
    textContent: children.text || "",
    getAttribute: (k) => (map.has(k) ? map.get(k) : null),
    setAttribute: (k, v) => map.set(k, String(v)),
    querySelector: (sel) => (children[sel] || null)
  }
}

let mod, listeners, observers, rootClasses, toggles, triggers

function stage() {
  // Two toggles, as the page renders them: the desktop rail and the phone row.
  toggles = [element({ title: "Toggle theme" }), element({ title: "Toggle theme" })]
  const name = element({}, { text: "\n  Christopher_Montgomery_Wellin  \n" })
  triggers = [element({ type: "button" }, { "[data-nav-name]": name })]
  rootClasses = new Set(["dark"])
}

async function boot() {
  listeners = {}
  observers = []
  globalThis.document = {
    addEventListener: (type, fn) => { listeners[type] = fn },
    documentElement: { classList: { contains: (c) => rootClasses.has(c) } },
    querySelectorAll: (sel) => ({ ".nav-toggle-icon > button": toggles, "[data-nav-name-trigger]": triggers }[sel] || [])
  }
  globalThis.MutationObserver = class {
    constructor(cb) { this.cb = cb; observers.push(this) }
    observe(target, options) { this.target = target; this.options = options }
    fire() { this.cb([]) }
  }
  mod = await import("data:text/javascript;base64," + Buffer.from(SOURCE + `\n// ${Math.random()}`).toString("base64"))
}

beforeEach(async () => {
  stage()
  await boot()
})

test("every theme toggle gets a type, a name and its pressed state on turbo:load", () => {
  listeners["turbo:load"]()
  for (const t of toggles) {
    assert.equal(t.getAttribute("type"), "button")
    assert.equal(t.getAttribute("aria-label"), "Dark theme")
    assert.equal(t.getAttribute("aria-pressed"), "true")
  }
})

test("the pressed state follows the root's dark class when the theme flips", () => {
  listeners["turbo:load"]()
  rootClasses.delete("dark")
  observers.at(-1).fire()
  for (const t of toggles) assert.equal(t.getAttribute("aria-pressed"), "false")
  assert.deepEqual(observers.at(-1).options, { attributes: true, attributeFilter: ["class"] })
})

test("a second turbo:load relabels without stacking a second observer", () => {
  listeners["turbo:load"]()
  listeners["turbo:load"]()
  assert.equal(observers.length, 1)
})

test("an existing button type is kept", () => {
  toggles[0].setAttribute("type", "submit")
  mod.labelThemeToggles(document, false)
  assert.equal(toggles[0].getAttribute("type"), "submit")
  assert.equal(toggles[1].getAttribute("type"), "button")
})

test("the name control's title is the whole name, whitespace collapsed", () => {
  listeners["turbo:load"]()
  assert.equal(triggers[0].getAttribute("title"), "Christopher_Montgomery_Wellin")
})

test("a name control with no name text gets no empty title", () => {
  triggers = [element({}, {})]
  mod.titleNames(document)
  assert.equal(triggers[0].getAttribute("title"), null)
})
