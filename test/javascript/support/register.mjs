// `node --import ./test/javascript/support/register.mjs --test ...` lets a test
// import an app module by its importmap name ("turf/scoring", "studio/studio_confetti",
// "wallet_signal"), through studio-engine's shared hook, plus Turf's alias stubs
// (alias_hooks.mjs). test/lib/javascript_unit_test.rb passes it on every run.
import { register } from "node:module"
import { importmapHookOptions, toolingDir } from "./importmap.mjs"

const { registerImportmapHooks } = await import(new URL("node_test/register.mjs", toolingDir()))
registerImportmapHooks(importmapHookOptions())
register("./alias_hooks.mjs", import.meta.url)
