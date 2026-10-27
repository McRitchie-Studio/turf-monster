// Where studio-engine's Node tooling package is (lib/studio/node_tooling in the
// gem): STUDIO_NODE_TOOLING when set, else the link `bin/rails studio:node:link`
// writes at node_modules/.studio-engine. playwright.config.js and the specs
// require the package through this one resolver.
const path = require("node:path");

const ROOT = path.join(__dirname, "..");

function studioToolingDir(env = process.env) {
  return env.STUDIO_NODE_TOOLING || path.join(ROOT, "node_modules", ".studio-engine");
}

function requireStudioTooling(file) {
  const dir = studioToolingDir();
  try {
    return require(path.join(dir, file));
  } catch (error) {
    throw new Error(
      `studio-engine's Node tooling is not at ${dir}. ` +
        "Run `bin/rails studio:node:link` after `npm ci`, or export STUDIO_NODE_TOOLING. " +
        `(${error.message})`
    );
  }
}

module.exports = { studioToolingDir, requireStudioTooling };
