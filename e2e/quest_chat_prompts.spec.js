// Quest 2 composer nudge — the typed placeholder deck and its REST state.
//
// This spec exists because the coverage it replaces did not bite. The original
// test assert_match'ed the literal source lines of the state machine out of the
// rendered <script>; review demonstrated it green against BOTH the broken and
// the fixed behaviour, so it discriminated nothing about resting while being the
// only declared coverage for the acceptance criterion. Grepping a script proves
// the text is present, never that it runs. These assertions drive the real
// component in a real browser instead.
//
// Two things are pinned here, both of which were live defects:
//
//   1. REST SURVIVES RE-ENTRY. The typewriter types the deck once and stops on
//      the last line. startPrompts() used to guard on the _promptTimer handle,
//      which _promptStep() nulls when it rests — so a rested component read as
//      idle, and a second quest-chat-active re-entered at phase 'hold', erased
//      the rested line, walked the index past the end of the deck and left an
//      EMPTY placeholder for good. It is reached by an ordinary click:
//      contests/_quest_chat puts @click="focusChat()" on the whole card, and
//      focusChat() dispatches quest-chat-active.
//
//   2. THE REST LINE FITS. The rested line is the one the feature is designed to
//      leave on screen, so it is the one that must not wrap. Measured against the
//      composer's real content box at 375px — the mobile chat tab — in the real
//      font, because a character budget in the helper is only a proxy for width.

const { test, expect } = require("@playwright/test");
const { login, reseed, createActiveEntry, setQuestState } = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";
const CONTEST_PATH = `/contests/${CONTEST_SLUG}`;

// Park the user on quest 2: username already changed, first message not sent.
async function entrantOnChatQuest(page) {
  const email = `quest-chat-${Date.now().toString(36)}@mcritchie.studio`;
  await login(page, email);
  await createActiveEntry(page, CONTEST_SLUG);
  await setQuestState(page, { username_changed: true });
  await page.goto(CONTEST_PATH);
  await expect(page.getByText("Send Your First Message")).toBeVisible();
}

// The deck is typed one line at a time and rests on the last; wait for the
// placeholder to hold that final line rather than sleeping a fixed span.
async function restedPlaceholder(page) {
  const input = page.locator("#contest-chat-input");
  await page.waitForFunction(
    (last) => document.getElementById("contest-chat-input").placeholder === last,
    await page.locator("[data-chat-prompts]").getAttribute("data-chat-prompts").then((d) => JSON.parse(d).at(-1)),
    { timeout: 40_000, polling: 200 }
  );
  return input.getAttribute("placeholder");
}

test.beforeEach(async ({ request }) => await reseed(request));

test("the rested placeholder survives another quest-chat-active ping", async ({ page }) => {
  test.setTimeout(90_000);
  await entrantOnChatQuest(page);

  const rested = await restedPlaceholder(page);
  expect(rested).not.toBe("");

  // The ordinary interaction: clicking the quest card re-dispatches the event.
  // Twice, because the first re-entry is what used to erase the line and the
  // second is what used to walk the index off the end of the deck.
  const card = page.getByText("Send Your First Message");
  await card.click();
  await page.waitForTimeout(1500);
  await card.click();
  await page.waitForTimeout(2500);

  const after = await page.locator("#contest-chat-input").getAttribute("placeholder");
  expect(after, "a rested deck must not restart, erase, or blank itself").toBe(rested);
  // Belt and braces: an empty placeholder is the exact failure this guards, and
  // it also strips the control's visible prompt.
  expect(after).not.toBe("");
});

// The longest REAL team names that survive the helper's name budget
// (contests_helper#CHAT_PROMPT_NAME_BUDGET, 10). Anything longer is replaced by
// short_name before it reaches the composer, so these are the genuine worst case.
// test/helpers/contests_helper_test.rb asserts this exact list stays within the
// budget, so the two cannot drift apart silently.
//
// They are listed HERE, rather than left to whatever team the seed happens to
// pick, because the seeded entrant draws "Jets" — four characters. A width test
// measuring only the rendered line passes on copy that overflows for every other
// team in the league, which is precisely the kind of test that does not bite.
//
// This list previously ran to 13 characters ("United States"), which fit the
// 206px box on macOS and FAILED at 187.0px in the CI runner's 183px box. The
// box width is environment-dependent — Linux reserves real scrollbar width where
// macOS overlays it — so measure where you run and never port a budget between
// machines.
const LONGEST_BUDGETED_NAMES = ["Commanders", "Buccaneers", "Uzbekistan", "Cape Verde", "Cardinals"];

test("the rest line fits the composer at 375px", async ({ page }) => {
  test.setTimeout(90_000);
  await page.setViewportSize({ width: 375, height: 900 });
  await entrantOnChatQuest(page);

  // The chat panel lives behind a tab on mobile; the deck plays out either way,
  // but it has no layout to measure until the tab is shown.
  await page.getByRole("button", { name: "Chat", exact: true }).click();
  await expect(page.locator("#contest-chat-input")).toBeVisible();

  const rested = await restedPlaceholder(page);

  const m = await page.evaluate((names) => {
    const el = document.getElementById("contest-chat-input");
    const cs = getComputedStyle(el);
    const box = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    const ctx = document.createElement("canvas").getContext("2d");
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`;
    const shown = el.placeholder;
    // Swap the rendered line's team name for each worst-case name, so the
    // measurement tracks the REAL sentence the helper builds rather than a
    // copy of it that could drift out of step.
    const tail = shown.slice(shown.indexOf(" "));
    return {
      box,
      shown: { text: shown, width: ctx.measureText(shown).width },
      worst: names.map((n) => ({ text: n + tail, width: ctx.measureText(n + tail).width })),
    };
  }, LONGEST_BUDGETED_NAMES);

  expect(m.box, "the mobile composer should have a real content box").toBeGreaterThan(100);
  expect(rested).toBe(m.shown.text);

  for (const line of [m.shown, ...m.worst]) {
    expect(
      line.width,
      `"${line.text}" measures ${line.width.toFixed(1)}px in a ${m.box.toFixed(1)}px box — it wraps and slices mid-glyph`
    ).toBeLessThanOrEqual(m.box);
  }
});
