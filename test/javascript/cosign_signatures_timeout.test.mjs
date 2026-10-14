// cosign_signatures.js waits for Phantom to switch accounts between prompts.
// The default wait is three minutes; a nonce-anchored signer-console wire has
// no blockhash to outlive, so the caller passes a longer one. These pin that
// the caller's limit is the one honoured.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const SOURCE = readFileSync(
  fileURLToPath(new URL("../../app/javascript/cosign_signatures.js", import.meta.url)), "utf8"
)

function load() {
  const window = {}
  vm.runInNewContext(SOURCE, { window, setInterval, clearInterval })
  return window.cosignSignatures
}

const key = (b58) => ({ toBase58: () => b58 })

test("a caller's switch limit is the one honoured", async () => {
  const { awaitAccount } = load()
  const provider = { publicKey: key("A") }
  const started = Date.now()
  await assert.rejects(awaitAccount(provider, "B", null, 800), /Timed out waiting for Phantom to switch to B/)
  assert.ok(Date.now() - started < 5000, "it gave up at the caller's limit, not the three-minute default")
})

test("an account that arrives inside the limit resolves", async () => {
  const { awaitAccount } = load()
  const provider = { publicKey: key("A") }
  setTimeout(() => { provider.publicKey = key("B") }, 100)
  await awaitAccount(provider, "B", null, 60000)
})
