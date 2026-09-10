// Pure-parser unit tests for the generalized DraftKings scraper.
// Runs with Node's built-in test runner (no deps, no browser):  npm run test:scrape
const { test } = require("node:test");
const assert = require("node:assert");
const { parseTeamTotals, parseArgs, resolveLeague } = require("./scrape_draftkings");

const SOCCER = {
  teamMap: { "mexico": "MEX", "south africa": "RSA" },
  marketLabel: "Team Total Goals",
};

test("parses a team's total, picking the O/U closest to even money", () => {
  const text = [
    "Mexico", "VS", "South Africa",
    "Mexico: Team Total Goals",
    "Over", "0.5", "-1000",
    "Under", "0.5", "+390",
    "Over", "1.5", "-110",
    "Under", "1.5", "-105",
  ].join("\n");

  const rows = parseTeamTotals(text, SOCCER);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].short_name, "MEX");
  assert.equal(rows[0].opponent_short_name, "RSA");
  assert.equal(rows[0].line, 1.5, "1.5 (-110) is closest to even money");
  assert.equal(rows[0].over_odds, -110);
  assert.equal(rows[0].under_odds, -105);
});

test("is total over garbled input (a layout change yields [], not a throw)", () => {
  assert.deepEqual(parseTeamTotals("nothing\nuseful\nhere", SOCCER), []);
});

test("parseArgs defaults to soccer/world-cup-2026 and reads flags", () => {
  assert.deepEqual(parseArgs([]), {
    sport: "soccer", league: "world-cup-2026", week: null, headed: false, debug: false,
  });
  const nfl = parseArgs(["--sport", "nfl", "--week", "3"]);
  assert.equal(nfl.sport, "nfl");
  assert.equal(nfl.league, "regular-season", "defaults league per sport");
  assert.equal(nfl.week, "3");
});

test("resolveLeague refuses the PLANNED nfl slot loudly", () => {
  assert.throws(() => resolveLeague(parseArgs(["--sport", "nfl"])), /PLANNED/);
});

test("resolveLeague returns the wired soccer config", () => {
  const { key, config } = resolveLeague(parseArgs([]));
  assert.equal(key, "soccer/world-cup-2026");
  assert.equal(typeof config.parse, "function");
});
