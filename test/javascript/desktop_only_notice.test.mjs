import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { noticeFor } = await loadTurfModule("desktop_only_notice")

const phone = { isMobile: () => true, desktopOnlyMessage: () => "Open this page on a computer." }
const desktop = { isMobile: () => false, desktopOnlyMessage: () => "Open this page on a computer." }

test("a phone sees the notice, in the provider's own words", () => {
  assert.deepEqual(noticeFor(phone), { show: true, message: "Open this page on a computer." })
})

test("a desktop sees nothing", () => {
  assert.deepEqual(noticeFor(desktop), { show: false, message: null })
})

test("no provider, or one that cannot say, shows nothing", () => {
  assert.deepEqual(noticeFor(undefined), { show: false, message: null })
  assert.deepEqual(noticeFor({}), { show: false, message: null })
})

test("a phone whose provider has no sentence still shows the notice", () => {
  assert.deepEqual(noticeFor({ isMobile: () => true }), { show: true, message: null })
})
