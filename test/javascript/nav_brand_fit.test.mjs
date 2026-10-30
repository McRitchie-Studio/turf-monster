// app/javascript/nav_brand_fit.js: the navbar draws "Turf Monster" only where
// it fits whole on one line beside the mascot and the links, and says so on
// the header (data-nav-brand="fit" | "tight"). /tasks/turf-navbar-logo-when-tight.
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const SOURCE = readFileSync(fileURLToPath(new URL("../../app/javascript/nav_brand_fit.js", import.meta.url)), "utf8")

// A header whose geometry a test sets. The logo link is 48px of mascot plus
// the words; the words only take room while they are in flow, which in the
// page means "not tight" or "being measured". The nav is the desktop links
// (offsetWidth 0 below 768px, where they have their own row).
function stage({ room = 472, words = 208, nav = 188, gap = 24 } = {}) {
  const attrs = new Map()
  const props = new Map()
  const seen = []
  const header = {
    getAttribute: (k) => (attrs.has(k) ? attrs.get(k) : null),
    setAttribute: (k, v) => { attrs.set(k, v); seen.push([k, v, props.get("--nav-p")]) },
    removeAttribute: (k) => attrs.delete(k),
    style: {
      getPropertyValue: (k) => props.get(k) || "",
      setProperty: (k, v) => props.set(k, v),
      removeProperty: (k) => props.delete(k)
    },
    querySelector: (sel) => (sel === ".nav-logo-link" ? link : null)
  }
  const inFlow = () => attrs.has("data-nav-brand-measure") || attrs.get("data-nav-brand") !== "tight"
  // Outside the measure, the row lets the link shrink: it never reports past
  // the room. Inside it nothing shrinks, which is what the measure asks.
  const shrinkable = () => !attrs.has("data-nav-brand-measure")
  const world = { room, words, nav, gap }
  const link = {
    offsetLeft: 16,
    get offsetWidth() {
      const full = 48 + (inFlow() ? world.words : 0)
      const navW = world.nav
      return shrinkable() ? Math.min(full, world.room - (navW ? navW + world.gap : 0)) : full
    }
  }
  const navEl = {
    tagName: "NAV",
    children: [{}, {}],
    get offsetWidth() { return world.nav },
    get offsetLeft() { return link.offsetLeft + link.offsetWidth + world.gap }
  }
  const row = {
    offsetLeft: 16,
    get clientWidth() { return world.room },
    get children() { return world.nav ? [link, navEl] : [link] }
  }
  link.parentElement = row
  return { header, attrs, props, seen, world, row, navEl }
}

let mod, listeners, observers, w

async function boot() {
  listeners = {}
  observers = []
  globalThis.document = {
    addEventListener: (type, fn) => { listeners[type] = fn },
    querySelectorAll: () => [w.header],
    fonts: { addEventListener: (type, fn) => { listeners[`fonts:${type}`] = fn } }
  }
  globalThis.ResizeObserver = class {
    constructor(cb) { this.cb = cb; this.targets = []; observers.push(this) }
    observe(target) { this.targets.push(target) }
    disconnect() { this.targets = [] }
    report() { this.cb(this.targets.map((target) => ({ target }))) }
  }
  mod = await import("data:text/javascript;base64," + Buffer.from(SOURCE + `\n// ${Math.random()}`).toString("base64"))
}

beforeEach(async () => {
  w = stage()
  await boot()
})

test("room for mascot, words and links: fit", () => {
  assert.equal(mod.settle(w.header), "fit")
  assert.equal(w.attrs.get("data-nav-brand"), "fit")
})

test("a link row that runs past the room: tight, not an ellipsis", () => {
  // At rest 48 + 208 + 24 + 188 = 468 of 472 clears the 1px slack; 4px more
  // of nav ends exactly at the room's edge, which the slack refuses.
  w.world.nav = 188 + 4
  assert.equal(mod.settle(w.header), "tight")
})

test("the answer does not depend on the state it is in", () => {
  w.world.nav = 220
  assert.equal(mod.settle(w.header), "tight")
  // Hidden, the link is 48px wide and the row has room to spare; the measure
  // puts the words back before it reads, so it still says tight.
  assert.equal(mod.settle(w.header), "tight")
  w.world.nav = 100
  assert.equal(mod.settle(w.header), "fit")
  assert.equal(mod.settle(w.header), "fit")
})

test("below 768px the links are not in the row: the logo link alone decides", () => {
  w.world.nav = 0
  w.world.words = 164 // the words and the link's gap at 24px
  w.world.room = 212
  assert.equal(mod.settle(w.header), "tight")
  w.world.room = 260
  assert.equal(mod.settle(w.header), "fit")
})

test("it measures at rest and leaves no measure state or --nav-p behind", () => {
  w.props.set("--nav-p", "0.6")
  mod.settle(w.header)
  assert.equal(w.attrs.has("data-nav-brand-measure"), false)
  assert.equal(w.props.get("--nav-p"), "0.6")
  const measured = w.seen.find(([k]) => k === "data-nav-brand-measure")
  assert.ok(measured, "it set the measure state")
  w.props.delete("--nav-p")
  mod.settle(w.header)
  assert.equal(w.props.has("--nav-p"), false, "an unset --nav-p stays unset")
})

test("turbo:load answers at once, then re-answers when the row or a nav item resizes", () => {
  listeners["turbo:load"]()
  assert.equal(w.attrs.get("data-nav-brand"), "fit")
  const ro = observers.at(-1)
  assert.ok(ro.targets.includes(w.row), "watches the row")
  assert.ok(ro.targets.includes(w.navEl), "watches the nav")
  assert.equal(ro.targets.length, 2 + w.navEl.children.length, "and each nav item")
  w.world.nav = 260 // the wallet chip hydrates wider
  ro.report()
  assert.equal(w.attrs.get("data-nav-brand"), "tight")
})

test("every navbar on the page is answered, a preview frame as well as the live header", () => {
  const preview = stage({ room: 300, nav: 0 })
  const live = w
  globalThis.document.querySelectorAll = () => [live.header, preview.header]
  listeners["turbo:load"]()
  assert.equal(live.attrs.get("data-nav-brand"), "fit")
  assert.equal(preview.attrs.get("data-nav-brand"), "fit")
  assert.equal(observers.length, 2, "one observer per header")
  preview.world.room = 200 // its slider narrows the frame
  observers[1].report()
  assert.equal(preview.attrs.get("data-nav-brand"), "tight")
  assert.equal(live.attrs.get("data-nav-brand"), "fit")
})

test("a font load re-answers", () => {
  listeners["turbo:load"]()
  w.world.words = 300
  listeners["fonts:loadingdone"]()
  assert.equal(w.attrs.get("data-nav-brand"), "tight")
})
