// The requests behind the dev score tools. No DOM.

const PATHS = {
  record: "/dev/live_scores/record",
  recordPlay: "/dev/live_scores/record_play",
  clear: "/dev/live_scores/clear_game",
  conclude: "/dev/live_scores/conclude_game"
}

// "<game slug>|<team slug>", the value of the team picker's options.
export function splitTarget(target) {
  const [ game_slug, team_slug ] = String(target).split("|")
  return { game_slug, team_slug }
}

// The path and JSON body of one tool's POST. `param` is the scoring type for
// record and the kind for recordPlay.
export function request(tool, target, param) {
  const { game_slug, team_slug } = splitTarget(target)
  const path = PATHS[tool]
  if (!path) throw new Error(`unknown dev score tool: ${tool}`)

  if (tool === "record") return { path, body: { game_slug, team_slug, scoring_type: param } }
  if (tool === "recordPlay") return { path, body: { game_slug, team_slug, kind: param } }
  return { path, body: { game_slug } }
}
