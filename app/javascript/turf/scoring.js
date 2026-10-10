// The goal console's rules: one game's state, its requests and its labels, and
// which cards the toolbar shows. No DOM.
//
// A game is { slug, homeScore, awayScore, status, homeSlug, awaySlug, goals },
// as the server sends it; a goal is { id, teamEmoji, minute }.

export function done(game) {
  return game.status === "completed"
}

export function scoreLine(game) {
  const home = game.homeScore == null ? "–" : game.homeScore
  const away = game.awayScore == null ? "–" : game.awayScore
  return home + " – " + away
}

export function statusLabel(game) {
  if (done(game)) return "FINAL"
  return game.status === "in_progress" ? "LIVE" : "Scheduled"
}

export function completeLabel(game) {
  return done(game) ? "Final ✓" : "Mark Final"
}

// The minute field's value as the request sends it: a number, or "" when the
// field is empty.
export function minuteValue(raw) {
  const number = parseFloat(raw)
  return Number.isNaN(number) ? "" : number
}

// The request that records a goal for `side` ("home" or "away").
export function addGoalRequest(game, side, minute) {
  const team_slug = side === "home" ? game.homeSlug : game.awaySlug
  return { url: `/admin/games/${game.slug}/goals`, method: "POST", body: { team_slug, minute } }
}

export function removeGoalRequest(game, id) {
  return { url: `/admin/games/${game.slug}/goals/${id}`, method: "DELETE", body: null }
}

export function completeRequest(game) {
  return { url: `/admin/games/${game.slug}/complete`, method: "POST", body: null }
}

// The game after a response: the server's score, status and goals. Throws the
// server's error when the response is not a success.
export function applyResponse(game, data) {
  if (!data.success) throw new Error(data.error || "Request failed")
  const { homeScore, awayScore, status, goals } = data.game
  return { ...game, homeScore, awayScore, status, goals }
}

// Whether the toolbar shows a card: its search text contains the lowercased
// query, and it is not a finished game while "Hide finished" is ticked.
export function cardVisible({ search, query, hideDone, done }) {
  const found = query === "" || String(search).includes(query.toLowerCase())
  return found && !(hideDone && done)
}
