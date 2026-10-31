const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// [e2e] THE SIGNED-IN NAVBAR WITH A LONG REAL NAME (/tasks/turf-navbar-polish).
//
// A real account, signed in, with a real 29-character username set through the
// same validation a user's own change goes through (POST /test/set_username), so
// the server renders the name everywhere it renders it: the name control in
// row 1, the avatar's label, and the name control's title (the engine's).
//
//   · 360, 768, 1024, 1280, light and dark: no sideways scroll, the avatar on
//     screen, every tab stop in the header named by its text or aria-label (a
//     title alone does not count), the theme toggles' pressed state matching
//     the theme, and from 768 the name truncating with its full text as a title.
//   · 1024: the name gets its full 7rem cap (it had about 67px); at 768 the
//     row has no slack to give, so there it truncates with its title.
//   · without :has(): every :has() rule is deleted from the page's stylesheets,
//     as a browser without the selector drops them, and the layout still holds.
//   · the hovers stay as they were: the gear, the name and the avatar open one
//     sidebar and light as one group (engine.css, THE ACCOUNT GROUP), each in
//     its own way (the name and the gear take the primary colour, the avatar
//     glows), and the theme toggle (the engine names it) stays outside the group.
const EMAIL = "navbar-polish@e2e.test";
const LONG_NAME = "Christopher_Montgomery_Wellin";
const HEADER = "header[data-navbar-root]";
const WIDTHS = [360, 768, 1024, 1280];

async function signInWithLongName(page, request, theme) {
  await reseed(request);
  // The head's pre-paint script reads localStorage "theme" (dark unless "light").
  await page.addInitScript((t) => { try { localStorage.setItem("theme", t); } catch (_) {} }, theme);
  await login(page, EMAIL);
  const res = await page.request.post("/test/set_username", { data: { username: LONG_NAME } });
  expect(res.ok(), await res.text()).toBe(true);
}

// A new account's balance reads "$0", the narrowest the seat gets; most real
// rows read wider, and the row's slack is what this card is about. So the seat
// is given a five-digit balance in the page, as e2e/navbar_long_name.spec.js
// gives the name its text: the layout is the same whatever wrote the digits.
async function widenBalance(page) {
  await page.evaluate(async (sel) => {
    document.querySelectorAll(`${sel} [data-balance-display]`).forEach((el) => { el.textContent = "$10240"; });
    for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
  }, HEADER);
}

async function measure(page) {
  return page.evaluate((sel) => {
    const h = document.querySelector(sel);
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none";
    };
    const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; };
    const focusable = [...h.querySelectorAll("a[href], button, [tabindex], input, select, summary")]
      .filter((el) => el.tabIndex >= 0 && !el.disabled && visible(el));
    // Named by what a screen reader reads first: aria-label, aria-labelledby,
    // the visible text, or an image's alt. A title is the name of last resort.
    const named = (el) => {
      if ((el.getAttribute("aria-label") || "").trim()) return true;
      const by = el.getAttribute("aria-labelledby");
      if (by && by.split(/\s+/).some((id) => (document.getElementById(id)?.textContent || "").trim())) return true;
      if ((el.textContent || "").trim()) return true;
      return [...el.querySelectorAll("img[alt]")].some((img) => img.alt.trim());
    };
    const unnamed = focusable.filter((el) => !named(el)).map((el) => el.outerHTML.slice(0, 160));
    const toggles = [...h.querySelectorAll(".nav-toggle-icon > button")].map((b) => ({
      label: b.getAttribute("aria-label"), pressed: b.getAttribute("aria-pressed"), type: b.getAttribute("type"),
    }));
    const trigger = h.querySelector("[data-nav-name-trigger]");
    const nameEl = trigger && trigger.querySelector("[data-nav-name]");
    const avatar = h.querySelector("[data-nav-account]");
    const gear = [...h.querySelectorAll("[data-gear-sidebar-trigger]")].find(visible);
    // The row's left side: the links and the items after them (geo badge,
    // wallet signal) must end before the account column starts.
    const col = h.querySelector(".user-nav-col");
    const leftItems = [...h.querySelectorAll("[data-nav-links] a, .geo-badge, [data-wallet-signal]")]
      .filter((el) => visible(el) && !col.contains(el));
    return {
      leftEnd: Math.max(0, ...leftItems.map((el) => el.getBoundingClientRect().right)),
      colLeft: col.getBoundingClientRect().left,
      dark: document.documentElement.classList.contains("dark"),
      innerWidth, scrollWidth: document.documentElement.scrollWidth,
      avatar: box(avatar.querySelector("[aria-hidden]") || avatar), avatarLabel: avatar.getAttribute("aria-label"),
      unnamed, toggles, gear: gear && box(gear),
      nameVisible: !!(trigger && visible(trigger)),
      name: nameEl && visible(nameEl) ? {
        ...box(nameEl), title: trigger.getAttribute("title"), text: nameEl.textContent.trim(),
        truncated: nameEl.scrollWidth > nameEl.clientWidth, overflow: getComputedStyle(nameEl).textOverflow,
      } : null,
    };
  }, HEADER);
}

for (const theme of ["light", "dark"]) {
  test(`signed in with a 29-character name, ${theme}: 360, 768, 1024 and 1280 hold, every tab stop named`, async ({ page, request }, testInfo) => {
    test.setTimeout(90_000);
    await signInWithLongName(page, request, theme);

    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 800 });
      await page.goto("/contests");
      await expect(page.locator(`${HEADER} [data-nav-account]`)).toBeVisible();
      await page.waitForLoadState("networkidle");
      // The engine renders aria-label on the server, but aria-pressed is an
      // Alpine binding (:aria-pressed on the theme store); wait for Alpine to
      // have bound it rather than racing it.
      await expect(page.locator(`${HEADER} .nav-toggle-icon > button[aria-pressed]`)).toHaveCount(2);
      await widenBalance(page);

      const m = await measure(page);
      const msg = `${theme} ${width}px: ${JSON.stringify(m)}`;

      expect(m.dark, msg).toBe(theme === "dark");
      expect(m.scrollWidth, `no sideways scroll: ${msg}`).toBeLessThanOrEqual(m.innerWidth);
      expect(m.avatar.right, `the avatar stays on screen: ${msg}`).toBeLessThanOrEqual(m.innerWidth + 0.5);
      expect(m.avatarLabel, msg).toBe(LONG_NAME);
      expect(m.leftEnd, `the links and items end before the account column: ${msg}`).toBeLessThanOrEqual(m.colLeft + 0.5);
      expect(m.unnamed, `every tab stop has a name: ${msg}`).toEqual([]);
      // Two toggles per page, the desktop rail and the phone row.
      expect(m.toggles.length, msg).toBe(2);
      for (const t of m.toggles) {
        expect(t, msg).toEqual({ label: "Dark theme", pressed: theme === "dark" ? "true" : "false", type: "button" });
      }

      if (width < 768) {
        // Below md the name control is not rendered visible; the avatar,
        // labelled with the name, is the account.
        expect(m.nameVisible, msg).toBe(false);
      } else {
        expect(m.name, msg).not.toBeNull();
        expect(m.name.text, msg).toBe(LONG_NAME);
        expect(m.name.title, `the full name on hover: ${msg}`).toBe(LONG_NAME);
        expect(m.name.truncated, msg).toBe(true);
        expect(m.name.overflow, msg).toBe("ellipsis");
        expect(m.name.right, `the name ends before the avatar: ${msg}`).toBeLessThanOrEqual(m.avatar.left + 0.5);
        // At 768 the column stays on its 16.5rem floor: the geo badge ends
        // about 20px short of it, so there is no room to take, and the name
        // truncates with its title (about 55px beside a five-digit balance).
        // The column grows from there and the name has its full 7rem at 1024
        // (it had about 67px beside a four-digit balance).
        expect(m.name.width, msg).toBeGreaterThanOrEqual(width >= 1024 ? 111 : 48);
      }

      await testInfo.attach(`navbar-${theme}-${width}.png`, {
        body: await page.locator(HEADER).screenshot(), contentType: "image/png",
      });
    }
  });
}

test("without :has() (every :has() rule deleted) a long name still keeps the avatar on screen at 768 and 1024", async ({ page, request }) => {
  await signInWithLongName(page, request, "dark");
  for (const width of [768, 1024]) {
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/contests");
    await expect(page.locator(`${HEADER} [data-nav-account]`)).toBeVisible();
    await page.waitForLoadState("networkidle");

    // What an older Firefox or Safari does with a selector it cannot parse:
    // the whole rule is dropped. Count what was deleted, so the strip cannot
    // pass by deleting nothing.
    const stripped = await page.evaluate(() => {
      let navRules = 0;
      const strip = (list) => {
        for (let i = list.cssRules.length - 1; i >= 0; i--) {
          const rule = list.cssRules[i];
          if (rule.selectorText && rule.selectorText.includes(":has(")) {
            if (rule.selectorText.includes("data-nav-tools")) navRules += 1;
            list.deleteRule(i);
          } else if (rule.cssRules) {
            strip(rule);
          }
        }
      };
      for (const sheet of document.styleSheets) { try { strip(sheet); } catch (_) { /* cross-origin */ } }
      return navRules;
    });
    expect(stripped, "the navbar's :has() rule was found and removed").toBeGreaterThan(0);
    await widenBalance(page);
    for (let i = 0; i < 2; i++) await page.evaluate(() => new Promise((r) => requestAnimationFrame(r)));

    const m = await measure(page);
    const msg = `${width}px without :has(): ${JSON.stringify(m)}`;
    expect(m.scrollWidth, `no sideways scroll: ${msg}`).toBeLessThanOrEqual(m.innerWidth);
    expect(m.avatar.right, `the avatar stays on screen: ${msg}`).toBeLessThanOrEqual(m.innerWidth + 0.5);
    expect(m.name.truncated, msg).toBe(true);
    expect(m.name.right, `the name ends before the avatar: ${msg}`).toBeLessThanOrEqual(m.avatar.left + 0.5);
    expect(m.name.left, `the name starts after the gear: ${msg}`).toBeGreaterThanOrEqual(m.gear.right - 0.5);
  }
});

test("the hovers stay as they were: name, avatar and gear light as one group, each its own way; the theme toggle stays out", async ({ page, request }) => {
  await signInWithLongName(page, request, "dark");
  await page.setViewportSize({ width: 1024, height: 800 });
  await page.goto("/contests");
  await page.waitForLoadState("networkidle");
  const name = page.locator(`${HEADER} [data-nav-name-trigger] [data-nav-name]`);
  const avatar = page.locator(`${HEADER} [data-nav-account] > [aria-hidden] > *`).first();
  const gear = page.locator(`${HEADER} [data-nav-tools] [data-gear-sidebar-trigger]`);
  const look = async () => ({
    name: await name.evaluate((el) => getComputedStyle(el).color),
    avatar: await avatar.evaluate((el) => getComputedStyle(el).boxShadow),
    gear: await gear.evaluate((el) => getComputedStyle(el).color),
  });

  await page.mouse.move(5, 400);
  const rest = await look();
  expect(rest.avatar, "the avatar has no glow at rest").toBe("none");

  for (const [label, target] of [
    ["name", page.locator(`${HEADER} [data-nav-name-trigger]`)],
    ["avatar", page.locator(`${HEADER} [data-nav-account]`)],
    ["gear", gear],
  ]) {
    await page.mouse.move(5, 400);
    await expect.poll(look, { message: `back to rest before the ${label}` }).toEqual(rest);
    await target.hover();
    await expect.poll(async () => {
      const lit = await look();
      return { name: lit.name !== rest.name, avatar: lit.avatar !== "none", gear: lit.gear !== rest.gear };
    }, { message: `pointing at the ${label} lights the name, the avatar's glow and the gear` }).toEqual({ name: true, avatar: true, gear: true });
  }

  await page.mouse.move(5, 400);
  await expect.poll(look).toEqual(rest);
  await page.locator(`${HEADER} [data-nav-tools] .nav-toggle-icon > button`).hover();
  // Give a wrong rule time to apply, then hold the line.
  await page.waitForTimeout(300);
  expect(await look(), "the theme toggle is not part of the account group").toEqual(rest);
});
