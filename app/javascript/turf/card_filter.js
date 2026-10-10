// The rule behind the card-filter controller. No DOM.

// Whether a card stays visible. `text` is the card's searchable text,
// `values` its own value for each filter key. The query is trimmed and both
// sides are lowercased; a filter set to "all" passes every card, and any
// other value must equal the card's value exactly.
export function cardVisible({ text, values }, query, filters) {
  const q = String(query || "").toLowerCase().trim()
  const matchSearch = !q || String(text || "").toLowerCase().includes(q)
  const matchFilters = Object.keys(filters).every((key) => filters[key] === "all" || values[key] === filters[key])
  return matchSearch && matchFilters
}

// The count line under the search box: "3 players", "32 teams".
export function countLabel(count, noun) {
  return count + " " + noun
}
