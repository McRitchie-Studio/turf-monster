// The rules behind the leaderboard-poll controller. No DOM.

// How often the contest page asks whether the leaderboard changed.
export const POLL_MS = 90000

export function pollUrl(slug, version) {
  return "/c/" + slug + "/leaderboard_poll?version=" + version
}

// The fresh list to swap in, or null when nothing changed.
export function freshList(data) {
  return data && data.changed && data.html ? { html: data.html, version: data.version } : null
}
