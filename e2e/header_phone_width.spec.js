const { test, expect } = require("@playwright/test");
const { loginAdmin } = require("./helpers");

// THE TURF HEADER, ON A PHONE.
//
// ============ WHY THE OBVIOUS ASSERTION IS THE WRONG ONE ============
//
// `documentElement.scrollWidth > clientWidth` is the honest test for "this page
// scrolls sideways", and it is GREEN on this header at every width it is
// broken. MEASURED on /contests, signed in, with a $1504 balance, BEFORE the
// fix — documentElement against the app name's own box:
//
//     width   documentElement   left column   title right   title outside
//      320       320 / 320         0..96         156           +60.0px
//      344       344 / 344         0..120        156           +36.0px
//      360       360 / 360         0..136        156           +20.0px
//      412       412 / 412         0..172        173.6          +1.6px
//
// The wordmark was painting on top of the seeds bar and the wallet address in
// the column beside it — visible in a screenshot, invisible to every
// document-level measurement, because a box that overflows its SIBLING's
// territory never reaches documentElement. The header row is exactly 100% wide
// either way.
//
// So this file asserts CONTAINMENT, per column, and it does NOT assert the
// document's own width. The page this spec drives carries a horizontally
// scrolled contest rail and (outside production only) the engine's environment
// banner, which between them put documentElement at 331 against a 320px
// viewport before this change and after it, unchanged. Asserting that number
// here would import two unrelated defects into a header guard and teach the
// next reader that the header owns them. What is asserted instead is that
// nothing INSIDE the header reaches past the viewport edge.
//
// ============ WHY EACH ASSERTION IS ON THE BOX IT IS ON ============
//
// Three different boxes report "contained" while the header is visibly broken,
// and each one cost a measured round of this task:
//
//   · the <h1>. With min-w-0 on the chain it shrinks and its right edge sits
//     comfortably inside the column — while the SPAN inside it keeps its own
//     max-content width and paints 26px past. Measured at 320px: h1 46px wide
//     ending at 114 inside a column ending at 130, span "Monster" 88px wide
//     ending at 156. So the spans are what this file measures.
//   · the user column's scrollWidth. It reports a contented fit down to an
//     imposed 122px, because the seeds bar overflows Div 1 (which is min-w-0)
//     rather than the column. The real floor is 190px, where the bar starts
//     sliding UNDER the avatar. So that pair is measured against each other.
//   · scrollWidth vs clientWidth on the span itself. Both round to the integer
//     88 while the renderer compares 88.05 against 88.00 and draws an ellipsis.
//     Not usable as an "is the wordmark whole" check; a screenshot is.
//
// ============ WHY THIS APP NEEDED ITS OWN SPEC ============
//
// studio-engine shipped the same repair in 0.77.1 and turf-monster gets none of
// it: this app renders its own fork of layouts/_navbar and declares its own
// `.user-nav-col` steps in app/assets/tailwind/application.css. The two headers
// are not the same shape either — turf's right column carries a 5-section seeds
// bar with a hard `min-w-[8rem]` plus a flex-shrink-0 avatar, so it has a
// content floor the engine's column does not, and a cap tuned for the engine
// starves this one. Both directions are asserted here for that reason.
//
// ============ WHY THE FIXTURE IS A SIGNED-IN ADMIN ============
//
// The right-hand column — the half that cannot shrink — does not render at all
// for a signed-out visitor, so a signed-out fixture measures a header that
// cannot exhibit this defect. loginAdmin() also gives the seeds bar its wallet
// label (`truncated_solana`), which is the element the wordmark was painting
// over, and exposeBalance() stands the balance up: the server renders that link
// `hidden` while the navbar cache is cold, so an unstressed fixture measures a
// narrower right column than production ever shows.

// 320 is the iPhone SE (1st gen) and the narrowest screen anyone still ships;
// 344 is the Galaxy Z Flip cover screen; 360 is the most common Android; 390 is
// the iPhone 12-16 class and the width in the acceptance criterion; 412 is
// Pixel; 430 is iPhone Pro Max. Not a taste list — 320, 344, 360 and 412 each
// measured the wordmark outside its own column before this change.
const WIDTHS = [320, 344, 360, 390, 412, 430];
const PHONE = { width: 390, height: 844 };

async function exposeBalance(page) {
  await page.evaluate(() => {
    const badge = document.querySelector("[data-free-entry-badge]");
    if (badge) {
      badge.classList.remove("hidden");
      badge.dataset.tokenCount = "1";
    }
    const balance = document.querySelector("[data-balance-display]");
    if (balance) {
      balance.classList.remove("hidden");
      balance.textContent = "$1504";
    }
    // One face at a time: a $0-with-token seed renders "Free Entry" ACTIVE.
    const feLabel = document.querySelector("[data-free-entry-label]");
    if (feLabel) feLabel.classList.remove("is-active");
  });
}

async function readHeaderGeometry(page) {
  return await page.evaluate(() => {
    const de = document.documentElement;
    const viewport = de.clientWidth;
    const root = document.querySelector("[data-navbar-root]");

    // Scoped to the header on purpose — see the note at the top of this file
    // about the rail and the banner owning the document's own overflow.
    const past = [];
    const walk = (el) => {
      const style = getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") return;
      const box = el.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) return;
      if (box.right > viewport + 0.5 || box.left < -0.5) {
        past.push({
          tag: el.tagName.toLowerCase(),
          className: (el.getAttribute("class") || "").slice(0, 70),
          right: Math.round(box.right * 10) / 10,
          width: Math.round(box.width * 10) / 10,
          // flex-shrink is reported because the ANSWER to this defect is an
          // ancestor with flex-shrink: 0, not the visible thing sticking out.
          flexShrink: style.flexShrink
        });
      }
      for (const child of el.children) walk(child);
    };
    walk(root);

    const round = (n) => Math.round(n * 10) / 10;
    const box = (el) => (el ? el.getBoundingClientRect() : null);
    const row = root.querySelector(".nav-row");
    const leftColumn = row && row.firstElementChild;
    const title = root.querySelector(".nav-title");
    const userColumn = root.querySelector(".user-nav-col");
    // Div 2 of components/_user_nav — the seeds bar's wrapper, which carries the
    // min-width that sets this column's floor.
    const seeds = userColumn && userColumn.querySelector('[class*="min-w-[8rem]"]');
    const avatarButton = userColumn && userColumn.querySelector("[data-profile-image-toggle]");
    const avatar = avatarButton && avatarButton.parentElement;
    const leftBox = box(leftColumn);
    const userBox = box(userColumn);

    return {
      viewport,
      documentScrollWidth: de.scrollWidth,
      documentClientWidth: de.clientWidth,
      pastViewport: past,
      headerRight: round(box(root).right),
      leftColumnWidth: leftColumn ? Math.round(leftBox.width) : null,
      leftColumnScrollWidth: leftColumn ? leftColumn.scrollWidth : null,
      leftColumnRight: leftBox ? round(leftBox.right) : null,
      titleRight: title ? round(box(title).right) : null,
      titleWidth: title ? round(box(title).width) : null,
      // The word boxes, which is where the defect actually lives.
      wordRights: title ? Array.from(title.children).map((s) => round(box(s).right)) : [],
      wordWidths: title ? Array.from(title.children).map((s) => round(box(s).width)) : [],
      userColumnLeft: userBox ? round(userBox.left) : null,
      userColumnWidth: userBox ? Math.round(userBox.width) : null,
      userColumnRight: userBox ? round(userBox.right) : null,
      seedsRight: seeds ? round(box(seeds).right) : null,
      seedsWidth: seeds ? round(box(seeds).width) : null,
      avatarLeft: avatar ? round(box(avatar).left) : null,
      avatarRight: avatar ? round(box(avatar).right) : null
    };
  });
}

async function openHeaderAt(page, width) {
  await page.setViewportSize({ width, height: 844 });
  await page.goto("/contests");
  await expect(page.locator("[data-username-display]").first()).toBeVisible();
  await exposeBalance(page);
}

test("no part of the signed-in header reaches past a phone's edge", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await loginAdmin(page);

  const report = [];
  for (const width of WIDTHS) {
    await openHeaderAt(page, width);
    const g = await readHeaderGeometry(page);
    report.push(`${width}px: header 0..${g.headerRight}`);

    expect(
      g.pastViewport,
      `at ${width}px these header elements extend past the viewport: ` +
        `${JSON.stringify(g.pastViewport, null, 2)}. All widths so far: ${report.join(", ")}`
    ).toEqual([]);

    expect(
      g.headerRight,
      `at ${width}px the header's own box ends at ${g.headerRight} in a ${g.viewport}px viewport`
    ).toBeLessThanOrEqual(g.viewport + 0.5);
  }
});

test("the app name stays inside its own column on every phone", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await loginAdmin(page);

  // EVERY WIDTH, NOT JUST 390, and that is measured rather than cautious. Each
  // piece of the fix was removed on its own against this loop:
  //
  //   align-items: stretch   RED at 320/344/360 only
  //   truncate on a span     RED at 320 only
  //   the h1's min-w-0       RED at 320 only
  //   the base band's cap    this assertion stayed GREEN — the cap buys how
  //                          much of the name a reader gets, not containment,
  //                          and the monotonicity test below is what caught it
  //
  // Written against 390px alone, three of those four would have shipped.
  for (const width of WIDTHS) {
    await openHeaderAt(page, width);
    const g = await readHeaderGeometry(page);

    // THE ASSERTION THAT CATCHES THE ORIGINAL DEFECT, stated on the WORD boxes.
    // The <h1> is not enough: with min-w-0 in place it shrinks and reports
    // itself contained while a span inside it keeps its own max-content width.
    // Measured with align-items left at its inherited `baseline` — h1 46px
    // ending at 114, span "Monster" 88px ending at 156, column ending at 130.
    const worst = Math.max(...g.wordRights);
    expect(
      worst,
      `at ${width}px a word of the app name ends at ${worst}, outside its own column ` +
        `(ends at ${g.leftColumnRight}), so it is drawing across the gutter and over the ` +
        `user column that starts at ${g.userColumnLeft}. Word boxes: ` +
        `${JSON.stringify(g.wordRights)} at widths ${JSON.stringify(g.wordWidths)}; the <h1> ` +
        `itself ends at ${g.titleRight} and would report this contained. documentElement ` +
        `reports ${g.documentScrollWidth}/${g.documentClientWidth}.`
    ).toBeLessThanOrEqual(g.leftColumnRight);

    // The two columns do not overlap. Stated on the BOXES rather than on the
    // text, because this is the property that survives a markup change renaming
    // .nav-title.
    expect(
      g.userColumnLeft,
      `at ${width}px the user column starts at ${g.userColumnLeft}, before the left ` +
        `column ends at ${g.leftColumnRight} — the two overlap`
    ).toBeGreaterThanOrEqual(g.leftColumnRight - 1);

    // The same defect from the other side, and the form that survives a rename:
    // a column whose scrollWidth exceeds its width is reporting that its
    // contents do not fit inside it. It holds at every width because a
    // truncating span clips its own overflow rather than propagating it.
    expect(
      g.leftColumnScrollWidth,
      `at ${width}px the header's left column reports scrollWidth ` +
        `${g.leftColumnScrollWidth} against a width of ${g.leftColumnWidth} — its ` +
        `contents do not fit inside it`
    ).toBeLessThanOrEqual(g.leftColumnWidth + 1);
  }
});

test("the user column still holds the seeds bar and the avatar apart", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await loginAdmin(page);

  // THE OTHER DIRECTION, and the one that makes this app's cap different from
  // the engine's. Narrowing the right column to buy the wordmark room is only a
  // fix if the right column still holds what is in it. The seeds bar declares
  // `min-w-[8rem]` and the avatar column is flex-shrink-0, so past some cap the
  // bar simply slides underneath the avatar.
  //
  // ASSERTED ON THE PAIR, not on the column's scrollWidth: measured with the
  // column forced to 130px, `scrollWidth <= clientWidth` still reported a fit
  // while the bar's right edge (122) was past the avatar's left edge (70). The
  // bar overflows Div 1, which is min-w-0, rather than the column — the same
  // blindness as the document-level check, one box in.
  for (const width of WIDTHS) {
    await openHeaderAt(page, width);
    const g = await readHeaderGeometry(page);

    expect(g.seedsRight, `at ${width}px the seeds bar did not render`).not.toBeNull();
    expect(g.avatarLeft, `at ${width}px the avatar did not render`).not.toBeNull();

    expect(
      g.seedsRight,
      `at ${width}px the seeds bar ends at ${g.seedsRight}, past the avatar's left edge ` +
        `at ${g.avatarLeft} — the cap took the user column below what its own contents ` +
        `need. The column runs ${g.userColumnLeft}..${g.userColumnRight} ` +
        `(${g.userColumnWidth}px) and the bar is ${g.seedsWidth}px wide.`
    ).toBeLessThanOrEqual(g.avatarLeft);

    expect(
      g.avatarRight,
      `at ${width}px the avatar ends at ${g.avatarRight}, past the column's own right ` +
        `edge at ${g.userColumnRight}`
    ).toBeLessThanOrEqual(g.userColumnRight + 0.5);
  }
});

test("a wider phone never shows less of the app name", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await loginAdmin(page);

  // MONOTONICITY, and it is not a nicety — it is a defect this KIND of fix
  // causes. Capping only the base band left the engine's 412px Pixel showing
  // 84px of the app's name while a 390px iPhone showed 107px, because 412 falls
  // in the next band up, which still carried a constant rem. A wider screen
  // showing less is indistinguishable from a bug to the person holding it.
  const measured = [];
  for (const width of WIDTHS) {
    await openHeaderAt(page, width);
    const g = await readHeaderGeometry(page);
    measured.push({
      width,
      titleWidth: g.titleWidth,
      userColumnWidth: g.userColumnWidth,
      leftColumnWidth: g.leftColumnWidth
    });
  }

  for (let i = 1; i < measured.length; i++) {
    expect(
      measured[i].titleWidth,
      `the app name is ${measured[i].titleWidth}px wide at ${measured[i].width}px but ` +
        `${measured[i - 1].titleWidth}px at the narrower ${measured[i - 1].width}px. ` +
        `Full series: ${JSON.stringify(measured)}`
    ).toBeGreaterThanOrEqual(measured[i - 1].titleWidth);

    // The column that was capped has to grow with the screen too, or the fix
    // has simply moved the non-monotonicity one box to the right.
    expect(
      measured[i].userColumnWidth,
      `the user column is ${measured[i].userColumnWidth}px at ${measured[i].width}px but ` +
        `${measured[i - 1].userColumnWidth}px at the narrower ${measured[i - 1].width}px. ` +
        `Full series: ${JSON.stringify(measured)}`
    ).toBeGreaterThanOrEqual(measured[i - 1].userColumnWidth);
  }
});

test("no phone loses navigation to make the header fit", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await loginAdmin(page);

  // THE FIX THAT IS A REGRESSION WEARING A FIX'S CLOTHES. `display: none` on
  // the mobile sub-navbar, the avatar, the seeds bar or the username would
  // contain the header at every width above and drop navigation on exactly the
  // phones this task is about. Below md the sub-navbar is the ONLY place a
  // phone gets the gear sidebar and the theme toggle — both are `hidden md:flex`
  // in the user column — so its links and controls are checked, not assumed.
  for (const width of WIDTHS) {
    await openHeaderAt(page, width);

    const nav = await page.evaluate(() => {
      const root = document.querySelector("[data-navbar-root]");
      const shown = (el) => {
        if (!el) return false;
        const s = getComputedStyle(el);
        const b = el.getBoundingClientRect();
        return s.display !== "none" && s.visibility !== "hidden" && b.width > 0 && b.height > 0;
      };
      const painted = (el) => {
        if (!el) return null;
        const s = getComputedStyle(el);
        const b = el.getBoundingClientRect();
        return {
          display: s.display,
          visibility: s.visibility,
          width: Math.round(b.width * 10) / 10,
          height: Math.round(b.height * 10) / 10
        };
      };
      const links = Array.from(root.querySelectorAll("a"))
        .filter((a) => ["Contests", "Rules"].includes(a.textContent.trim()))
        .filter(shown)
        .map((a) => a.textContent.trim());
      const userColumn = root.querySelector(".user-nav-col");
      return {
        links: [...new Set(links)].sort(),
        logo: painted(root.querySelector(".nav-logo")),
        title: painted(root.querySelector(".nav-title")),
        username: painted(root.querySelector("[data-username-display]")),
        avatar: painted(root.querySelector("[data-profile-image-toggle]")),
        seeds: painted(userColumn && userColumn.querySelector('[class*="min-w-[8rem]"]')),
        // Two gear triggers render: one in the user column (`hidden md:flex`,
        // so display:none here) and one in the mobile sub-navbar. Picking the
        // first match in document order finds the desktop one and measures a
        // zero box on every phone, so take the first that actually paints.
        gear: painted(
          Array.from(root.querySelectorAll("[data-gear-sidebar-trigger]")).find(shown)
        )
      };
    });

    expect(
      nav.links,
      `at ${width}px the header offers ${JSON.stringify(nav.links)} — both the Contests ` +
        "and Rules links must survive; hiding navigation is not a fit"
    ).toEqual(["Contests", "Rules"]);

    for (const part of ["logo", "title", "username", "avatar", "seeds", "gear"]) {
      expect(nav[part], `at ${width}px the header's ${part} is not rendered at all`).not.toBeNull();
      expect(
        nav[part].width,
        `at ${width}px the header's ${part} paints no box: ${JSON.stringify(nav[part])}`
      ).toBeGreaterThan(0);
    }
  }
});
