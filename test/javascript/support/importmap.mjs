// The importmap names Turf's node:test files may import by, mapped onto files
// the way config/importmap.rb pins them in the browser:
//
//   pin "wallet_signal"                          -> app/javascript/wallet_signal.js
//   pin "turf/<name>", "controllers/<name>"      -> app/javascript/{turf,controllers}/
//   studio-engine's "studio/<name>" pins          -> the gem's app/javascript/studio/
//
// studio-engine's Node tooling package (lib/studio/node_tooling in the gem)
// resolves these through its importmap hook; this file only names Turf's
// prefixes. test/lib/node_tooling_adoption_test.rb holds the map to every pin
// config/importmap.rb draws, so a new pinned directory cannot go unmapped.
import { realpathSync } from "node:fs"
import { fileURLToPath, pathToFileURL } from "node:url"

export const ROOT = new URL("../../../", import.meta.url)

// STUDIO_NODE_TOOLING first (the Ruby suite sets it to Studio::NodeTooling.root,
// because its CI job runs no `npm ci`), else the link `bin/rails studio:node:link`
// writes.
export function toolingDir(env = process.env) {
  const dir = env.STUDIO_NODE_TOOLING || fileURLToPath(new URL("node_modules/.studio-engine/", ROOT))
  return pathToFileURL(`${realpathSync(dir)}/`)
}

export function importmapHookOptions(env = process.env) {
  // The tooling package sits at <gem>/lib/studio/node_tooling, so the engine's
  // own modules are three directories up, at <gem>/app/javascript/studio.
  const engineStudio = new URL("../../../app/javascript/studio/", toolingDir(env)).href
  return {
    root: ROOT.href,
    prefixes: {
      turf: "app/javascript/turf/",
      controllers: "app/javascript/controllers/",
      studio: engineStudio
    },
    topLevelDir: "app/javascript/",
    esmDirs: ["app/javascript/", "test/javascript/"]
  }
}
