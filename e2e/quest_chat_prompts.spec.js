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
// pick, because the seeded entrant draws "Jets" — four characters. A check
// measuring only the rendered line passes on copy that overflows for every other
// team in the league, which is precisely the kind of test that does not bite.
const LONGEST_BUDGETED_NAMES = ["Commanders", "Buccaneers", "Uzbekistan", "Cape Verde", "Cardinals"];

// A name the budget REJECTS, kept here on purpose. The budget-surviving names
// above fit the 206px box on a Mac and only overflowed on CI's 183px one, so on
// a developer machine they exercise the clip guard not at all — remove the CSS
// rule and the assertions still pass. This line is longer than the composer in
// ANY environment, so it is what actually proves the guard is doing something.
const OVERSIZE_NAME = "Bosnia and Herzegovina";

// WHY THIS ASSERTS WRAPPING AND NOT WIDTH.
//
// The defect is that an over-long placeholder WRAPS into a text box built for one
// line and gets sliced through the middle of its glyphs. Not-wrapping is therefore
// the invariant, it is what `.chat-composer::placeholder` guarantees, and it holds
// in every environment.
//
// A `width <= box` assertion looked equivalent and is not. The content box is
// 206px in Chrome on macOS and 183px on the Linux CI runner (classic scrollbar vs
// overlay), so a copy budget tuned on one machine failed on the other — twice, in
// CI, on this very spec. Worse, character count barely tracks width at all:
// "Commanders" (10 chars) measures 172.1px and "United States" (13) measures
// 173.5px, so trimming the budget by three characters bought 1.4px.
//
// So: wrapping is asserted as a hard invariant for every worst-case name, and
// width is checked only for the line actually rendered — a copy-quality signal on
// the real path, not a cross-platform pixel prediction.
test("the rest line never wraps in the composer at 375px", async ({ page }) => {
  test.setTimeout(90_000);
  await page.setViewportSize({ width: 375, height: 900 });
  await entrantOnChatQuest(page);

  // The chat panel lives behind a tab on mobile; the deck plays out either way,
  // but it has no layout to measure until the tab is shown.
  await page.getByRole("button", { name: "Chat", exact: true }).click();
  await expect(page.locator("#contest-chat-input")).toBeVisible();

  const rested = await restedPlaceholder(page);

  const m = await page.evaluate(({ names, oversize }) => {
    const el = document.getElementById("contest-chat-input");
    const cs = getComputedStyle(el);
    const box = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    const ctx = document.createElement("canvas").getContext("2d");
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`;
    const shown = el.placeholder;

    const wraps = () => el.scrollHeight > el.clientHeight;
    const probes = [{ text: shown, wraps: wraps() }];
    // Swap the rendered line's team name for each worst-case name, so the probe
    // tracks the REAL sentence the helper builds rather than a copy of it.
    const tail = shown.slice(shown.indexOf(" "));
    for (const n of [...names, oversize]) {
      el.placeholder = n + tail;
      void el.offsetHeight; // force layout before reading
      probes.push({ text: n + tail, wraps: wraps() });
    }
    el.placeholder = shown;
    return { box, shown, shownWidth: ctx.measureText(shown).width, probes };
  }, { names: LONGEST_BUDGETED_NAMES, oversize: OVERSIZE_NAME });

  expect(m.box, "the mobile composer should have a real content box").toBeGreaterThan(100);
  expect(rested).toBe(m.shown);

  // The invariant: no line the helper can build may wrap.
  for (const probe of m.probes) {
    expect(probe.wraps, `"${probe.text}" wrapped the composer — it will render sliced mid-glyph`).toBe(false);
  }

  // Copy quality on the real path: the line actually rendered should be fully
  // visible, not merely clipped safely.
  expect(
    m.shownWidth,
    `the rendered rest line "${m.shown}" measures ${m.shownWidth.toFixed(1)}px in a ${m.box.toFixed(1)}px box`
  ).toBeLessThanOrEqual(m.box);
});
