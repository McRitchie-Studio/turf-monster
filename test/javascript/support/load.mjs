// Loads a logic module from app/javascript/turf as a data: module, so node
// needs no package.json and no loader hook. Such a module imports nothing.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const ROOT = fileURLToPath(new URL("../../../app/javascript/turf/", import.meta.url))

export function loadTurfModule(name) {
  const source = readFileSync(`${ROOT}${name}.js`, "utf8")
  return import("data:text/javascript;base64," + Buffer.from(source).toString("base64"))
}
