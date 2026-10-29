// app/javascript/nav_band_watch.js: when the account column's rows change
// size on a timeline header, the watcher asks the nav-collapse controller to
// measure again (a window resize). /tasks/turf-flaky-tests-steady: a change
// that lands before the ResizeObserver's first report must count too.
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const SOURCE = readFileSync(fileURLToPath(new URL("../../app/javascript/nav_band_watch.js", import.meta.url)), "utf8")

// A row whose height a test sets. As on the page at 1280: at rest the 40px
// avatar is taller than the two rows, collapsed the 32px avatar is not, so a
// row that grows changes the collapsed height and not the rest height.
function el(height) { return { offsetHeight: height, offsetWidth: 100 } }

function stage() {
  const props = new Map()
  const rows = [el(18), el(14)]
  const column = el(40)
  const brand = el(120)
  const header = {
    attrs: new Set(["data-nav-timeline", "data-nav-timeline-on"]),
    hasAttribute(name) { return this.attrs.has(name) },
    style: {
      getPropertyValue: (k) => props.get(k) || "",
      setProperty: (k, v) => props.set(k, v),
      removeProperty: (k) => props.delete(k)
    },
    get offsetHeight() {
      const sum = rows.reduce((total, row) => total + row.offsetHeight, 0)
      return props.get("--nav-p") === "1" ? Math.max(32, sum) + 16 : Math.max(40, sum) + 56
    },
    querySelector(sel) { return { ".user-nav-col": column, ".nav-logo-link": brand }[sel] }
  }
  column.querySelectorAll = () => rows
  // What the controller published when it measured: the header's own collapse.
  props.set("--nav-band", "48px")
  return { header, rows, column, brand, props }
}

let world, listeners, observers, resizes

async function boot() {
  listeners = {}
  observers = []
  resizes = 0
  globalThis.document = {
    addEventListener: (type, fn) => { listeners[type] = fn },
    querySelector: (sel) => (sel === "header[data-nav-timeline]" ? world.header : null)
  }
  globalThis.window = { dispatchEvent: (event) => { if (event.type === "resize") resizes += 1 } }
  globalThis.Event = class { constructor(type) { this.type = type } }
  globalThis.ResizeObserver = class {
    constructor(cb) { this.cb = cb; this.targets = []; observers.push(this) }
    observe(target) { this.targets.push(target) }
    disconnect() { this.targets = [] }
    // A report: what the browser sends on the next frame for these targets.
    report(targets = this.targets) { this.cb(targets.map((target) => ({ target }))) }
  }
  await import("data:text/javascript;base64," + Buffer.from(SOURCE + `\n// ${Math.random()}`).toString("base64"))
}

beforeEach(async () => {
  world = stage()
  await boot()
})

test("a steady column asks for nothing, on its first report or later", () => {
  listeners["turbo:load"]()
  const ro = observers.at(-1)
  ro.report()
  ro.report()
  assert.equal(resizes, 0)
})

test("a row that grows after the first report asks for a re-measure", () => {
  listeners["turbo:load"]()
  const ro = observers.at(-1)
  ro.report()
  world.rows[0].offsetHeight = 20
  ro.report([world.rows[0]])
  assert.equal(resizes, 1)
})

test("a row that grows after observe but before the first report still asks", () => {
  listeners["turbo:load"]()
  world.rows[0].offsetHeight = 20 // the balance hydrates before the first frame
  observers.at(-1).report()
  assert.equal(resizes, 1)
})

test("a row that grew before the watcher started: the first report checks the band", () => {
  world.rows[0].offsetHeight = 20 // after the controller measured, before turbo:load
  listeners["turbo:load"]()
  observers.at(-1).report()
  assert.equal(resizes, 1)
  assert.equal(world.props.has("--nav-p"), false, "the check leaves no --nav-p behind")
})

test("off the timeline (below 768px) a change asks for nothing", () => {
  world.header.attrs.delete("data-nav-timeline-on")
  listeners["turbo:load"]()
  world.rows[0].offsetHeight = 20
  observers.at(-1).report()
  assert.equal(resizes, 0)
})

test("the logo link counts by its width", () => {
  listeners["turbo:load"]()
  const ro = observers.at(-1)
  ro.report()
  world.brand.offsetWidth = 90
  ro.report([world.brand])
  assert.equal(resizes, 1)
})
