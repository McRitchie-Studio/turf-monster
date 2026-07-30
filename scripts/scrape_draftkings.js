/**
 * DraftKings Market Snapshot Scraper (generalized)
 *
 * Drives a headless browser against a DraftKings market page and extracts team
 * totals. Sport, league, and week are parameters; the league registry below
 * holds the per-league URL, team-name map, market label, and parser. This is the
 * reusable form docs/workflows/market-snapshot.md step 1 describes — the World
 * Cup soccer capture is the one wired parser; NFL is a registered-but-PLANNED
 * slot (its market has a different page shape, not yet mapped).
 *
 * Usage:
 *   npm run market-snapshot                                   # default soccer/world-cup-2026
 *   npm run market-snapshot -- --sport soccer --league world-cup-2026
 *   npm run market-snapshot -- --sport nfl --week 3           # 🔨 PLANNED — no parser wired
 *   npm run scrape            # back-compat alias (headless)
 *   npm run scrape:headed     # back-compat alias (visible browser)
 *
 * Flags:
 *   --sport <s>    sport key      (default: soccer)
 *   --league <l>   league key     (default: per-sport default below)
 *   --week <n>     captured week  (recorded; unused by the soccer parser)
 *   --headed       visible browser for debugging
 *   --debug        write screenshots + raw page text to scripts/data (git-ignored)
 *
 * Output (soccer): scripts/data/draftkings_team_totals.json — consumed by db/seeds.rb.
 */

const fs = require("fs");
const path = require("path");

const DATA_DIR = path.join(__dirname, "data");

// ── Team-name maps ───────────────────────────────────────────────────────────
const TEAM_NAME_MAP_SOCCER = {
  "mexico": "MEX", "south korea": "KOR", "korea republic": "KOR",
  "south africa": "RSA", "czechia": "CZE", "czech republic": "CZE",
  "canada": "CAN", "bosnia and herzegovina": "BIH", "bosnia & herzegovina": "BIH",
  "qatar": "QAT", "switzerland": "SUI", "brazil": "BRA", "morocco": "MAR",
  "haiti": "HAI", "scotland": "SCO", "united states": "USA", "usa": "USA",
  "paraguay": "PAR", "australia": "AUS", "turkey": "TUR", "türkiye": "TUR",
  "turkiye": "TUR", "germany": "GER", "curaçao": "CUW", "curacao": "CUW",
  "ivory coast": "CIV", "cote d'ivoire": "CIV", "côte d'ivoire": "CIV",
  "ecuador": "ECU", "netherlands": "NED", "japan": "JPN", "sweden": "SWE",
  "tunisia": "TUN", "belgium": "BEL", "egypt": "EGY", "iran": "IRN",
  "new zealand": "NZL", "spain": "ESP", "cape verde": "CPV", "cabo verde": "CPV",
  "saudi arabia": "KSA", "uruguay": "URU", "france": "FRA", "senegal": "SEN",
  "iraq": "IRQ", "norway": "NOR", "argentina": "ARG", "algeria": "ALG",
  "austria": "AUT", "jordan": "JOR", "portugal": "POR", "dr congo": "COD",
  "congo dr": "COD", "uzbekistan": "UZB", "colombia": "COL", "england": "ENG",
  "croatia": "CRO", "ghana": "GHA", "panama": "PAN",
};

// ── League registry — one entry per <sport>/<league> ─────────────────────────
const LEAGUES = {
  "soccer/world-cup-2026": {
    url: "https://sportsbook.draftkings.com/leagues/soccer/world-cup-2026?category=team-props&subcategory=total-team-goals",
    marketLabel: "Team Total Goals",
    teamMap: TEAM_NAME_MAP_SOCCER,
    outputPath: path.join(DATA_DIR, "draftkings_team_totals.json"),
    parse: parseTeamTotals,
  },
  // 🔨 PLANNED (market-snapshot follow-up): the NFL DraftKings market posts team
  // totals as POINTS (plus game total + spread primitives) on a differently
  // shaped page whose markup is not yet mapped, so no parser is wired here. Until
  // one is, NFL numbers are hand-transcribed into the seed CSV — see
  // docs/workflows/market-snapshot.md steps 1-2.
  "nfl/regular-season": {
    url: null,
    marketLabel: "Team Total Points",
    teamMap: null,
    outputPath: path.join(DATA_DIR, "nfl", "draftkings_team_totals.json"),
    parse: null,
  },
};

const DEFAULT_SPORT = "soccer";
const DEFAULT_LEAGUE = { soccer: "world-cup-2026", nfl: "regular-season" };

function lookupShortName(teamName, teamMap) {
  const normalized = teamName.trim().toLowerCase();
  if (teamMap[normalized]) return teamMap[normalized];
  for (const [key, val] of Object.entries(teamMap)) {
    if (normalized.includes(key) || key.includes(normalized)) return val;
  }
  return null;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Pure parser: DraftKings market page text -> team-total rows.
 *
 * Total over empty/garbled input (a layout change yields [] rather than an
 * exception), so callers can assert a minimum row count before writing a
 * dataset. Parameterized by `teamMap` and `marketLabel` so the same parse serves
 * any "<Team>: <marketLabel>" O/U board.
 */
function parseTeamTotals(pageText, { teamMap, marketLabel }) {
  const headerRegex = new RegExp(`^(.+?):\\s*${escapeRegExp(marketLabel)}$`, "i");
  const tailRegex = new RegExp(`:\\s*${escapeRegExp(marketLabel)}$`, "i");

  const lines = pageText.split("\n").map((l) => l.trim()).filter(Boolean);
  const results = [];

  // Track current game context (home VS away) to attach opponent.
  let currentGameTeams = [];

  for (let i = 0; i < lines.length; i++) {
    // Detect game separator: "TeamA\nVS\nTeamB"
    if (lines[i] === "VS" && i > 0 && i + 1 < lines.length) {
      const home = lookupShortName(lines[i - 1], teamMap);
      const away = lookupShortName(lines[i + 1], teamMap);
      if (home && away) {
        currentGameTeams = [home, away];
      }
    }

    const headerMatch = lines[i].match(headerRegex);
    if (!headerMatch) continue;

    const teamName = headerMatch[1].trim();
    const shortName = lookupShortName(teamName, teamMap);
    if (!shortName) {
      console.log(`  ? Unknown team: "${teamName}"`);
      continue;
    }

    // Determine opponent from current game context.
    let opponentShort = null;
    if (currentGameTeams.includes(shortName)) {
      opponentShort = currentGameTeams.find((t) => t !== shortName) || null;
    }

    // Collect all O/U lines for this team until we hit another header or VS.
    const overUnders = {};
    for (let j = i + 1; j < Math.min(lines.length, i + 60); j++) {
      if (lines[j].match(tailRegex) || lines[j] === "VS") break;

      if (lines[j] === "Over" && j + 2 < lines.length) {
        const line = parseFloat(lines[j + 1]);
        const odds = parseInt(lines[j + 2].replace("−", "-"));
        if (!isNaN(line) && !isNaN(odds)) {
          if (!overUnders[line]) overUnders[line] = {};
          overUnders[line].over_odds = odds;
        }
      }
      if (lines[j] === "Under" && j + 2 < lines.length) {
        const line = parseFloat(lines[j + 1]);
        const odds = parseInt(lines[j + 2].replace("−", "-"));
        if (!isNaN(line) && !isNaN(odds)) {
          if (!overUnders[line]) overUnders[line] = {};
          overUnders[line].under_odds = odds;
        }
      }
    }

    // Pick the line with over_odds closest to even money (±100).
    let bestLine = null;
    let bestDistance = Infinity;
    for (const [lineStr, data] of Object.entries(overUnders)) {
      if (data.over_odds == null) continue;
      const distance = data.over_odds >= 0
        ? Math.abs(data.over_odds - 100)
        : Math.abs(data.over_odds + 100);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestLine = parseFloat(lineStr);
      }
    }

    if (bestLine !== null && overUnders[bestLine]) {
      results.push({
        team_name: teamName,
        short_name: shortName,
        opponent_short_name: opponentShort,
        line: bestLine,
        over_odds: overUnders[bestLine].over_odds,
        under_odds: overUnders[bestLine].under_odds,
        all_lines: overUnders,
      });
    }
  }

  return results;
}

function parseArgs(argv) {
  const args = { sport: DEFAULT_SPORT, league: null, week: null, headed: false, debug: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--headed") args.headed = true;
    else if (a === "--debug") args.debug = true;
    else if (a === "--sport") args.sport = argv[++i];
    else if (a === "--league") args.league = argv[++i];
    else if (a === "--week") args.week = argv[++i];
  }
  if (!args.league) args.league = DEFAULT_LEAGUE[args.sport] || null;
  return args;
}

function resolveLeague(args) {
  const key = `${args.sport}/${args.league}`;
  const config = LEAGUES[key];
  if (!config) {
    const available = Object.keys(LEAGUES).join(", ");
    throw new Error(`No league config for "${key}". Available: ${available}`);
  }
  if (!config.url || !config.parse) {
    throw new Error(
      `🔨 PLANNED: no DraftKings scraper is wired for "${key}" yet. ` +
      `Its market page is not mapped — see docs/workflows/market-snapshot.md steps 1-2.`
    );
  }
  return { key, config };
}

async function scrape(args) {
  const { key, config } = resolveLeague(args);
  const { chromium } = require("playwright");

  console.log(`Capturing ${key}${args.week ? ` week ${args.week}` : ""} (${args.headed ? "headed" : "headless"})...`);

  const browser = await chromium.launch({ headless: !args.headed });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();
  const wantsDebugArtifacts = args.debug || args.headed;

  try {
    console.log(`Navigating to ${config.url}...`);
    await page.goto(config.url, { waitUntil: "domcontentloaded", timeout: 30000 });
    await page.waitForTimeout(4000);

    // Debug screenshots + raw text are opt-in (git-ignored) — they are no longer
    // committed to the repo; the MarketSnapshot artifact is the record of a run.
    if (wantsDebugArtifacts) {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      await page.screenshot({ path: path.join(DATA_DIR, "dk_market_page.png"), fullPage: true });
    }

    const pageContent = await page.evaluate(() => document.body.innerText);
    if (wantsDebugArtifacts) {
      fs.writeFileSync(path.join(DATA_DIR, "dk_market_raw.txt"), pageContent);
    }

    const results = config.parse(pageContent, config);

    console.log(`\n=== ${results.length} team totals extracted ===`);
    for (const entry of results) {
      console.log(`  ✓ ${entry.team_name} (${entry.short_name}) vs ${entry.opponent_short_name}: O/U ${entry.line} [${entry.over_odds}/${entry.under_odds}]`);
    }

    fs.mkdirSync(path.dirname(config.outputPath), { recursive: true });
    fs.writeFileSync(config.outputPath, JSON.stringify(results, null, 2));
    console.log(`Written to ${config.outputPath}`);

    if (args.headed) {
      console.log("\nBrowser open for inspection. Ctrl+C to close.");
      await page.waitForTimeout(300000);
    }
  } catch (err) {
    console.error("Scraper error:", err.message);
    if (wantsDebugArtifacts) {
      try {
        fs.mkdirSync(DATA_DIR, { recursive: true });
        await page.screenshot({ path: path.join(DATA_DIR, "dk_error.png"), fullPage: true });
      } catch { /* best-effort */ }
    }
  } finally {
    await browser.close();
  }
}

module.exports = { parseTeamTotals, lookupShortName, parseArgs, resolveLeague, LEAGUES };

if (require.main === module) {
  scrape(parseArgs(process.argv.slice(2))).catch(console.error);
}
