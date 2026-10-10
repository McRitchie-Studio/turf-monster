// The text filter behind the filter controller. No DOM.

// Whether an item whose text is `text` stays visible under `query`. The query
// is lowercased; the item's text is taken as written.
export function matches(text, query) {
  if (!query) return true
  return String(text).includes(query.toLowerCase())
}

// How many of `texts` stay visible under `query`.
export function visibleCount(texts, query) {
  return texts.filter((text) => matches(text, query)).length
}
