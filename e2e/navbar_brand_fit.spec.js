const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// [e2e] THE BRAND FITS OR IT IS THE MASCOT (/tasks/turf-navbar-logo-when-tight).
//
// Alex McRitchie, on a truncated "T… Mo…" at a mid width and a stacked
// "Turf / Monster" on a phone: "You should use the navbar logo." So at every
// width the wordmark is either WHOLE ON ONE LINE (no word clipped, one line
// box) or NOT DRAWN (the sr-only box: 1px, clipped), and the mascot keeps the
// name "Turf Monster". Never an ellipsis, never two lines.
//
//   · signed out and signed in, light and dark, 360 to 1280
//   · a wallet chip that hydrates wider at 768 (the mid-width ellipsis in his
//     screenshot): the words go, the links stay clear of the brand
//   · the desktop scroll collapse still shrinks the brand and keeps the answer
const HEADER = "header[data-navbar-root]";
const WIDTHS = [360, 414, 600, 768, 900, 1024, 1280];

async function brand(page) {
  return page.evaluate((sel) => {
    const h = document.querySelector(sel);
    const title = h.querySelector(".nav-title");
    const logo = h.querySelector(".nav-logo");
    const link = h.querySelector(".nav-logo-link");
    const tr = title.getBoundingClientRect();
    const words = [...title.children].map((s) => {
      const r = s.getBoundingClientRect();
      return { text: s.textContent, top: r.top, clipped: s.scrollWidth > s.clientWidth };
    });
    const nav = [...h.querySelectorAll(".nav-row nav")].find((n) => n.offsetWidth > 0);
    return {
      state: h.getAttribute("data-nav-brand"),
      hidden: tr.width <= 1 && tr.height <= 1 && getComputedStyle(title).position === "absolute",
      wordTops: words.map((w) => w.top),
      clipped: words.filter((w) => w.clipped).map((w) => w.text),
      titleHeight: tr.height,
      fontSize: parseFloat(getComputedStyle(title.lastElementChild).fontSize),
      logoAlt: logo && logo.getAttribute("alt"),
      linkRight: link.getBoundingClientRect().right,
      navLeft: nav ? nav.getBoundingClientRect().left : null,
      docOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    };
  }, HEADER);
}

function expectOneLineOrHidden(b, label) {
  expect(b.state, `${label}: the script has not answered`).toMatch(/^(fit|tight)$/);
  expect(b.logoAlt, `${label}: the mascot lost its name`).toBe("Turf Monster");
  if (b.state === "tight") {
    expect(b.hidden, `${label}: tight, but the words still paint`).toBe(true);
    return;
  }
  expect(b.hidden, `${label}: fit, but the words are hidden`).toBe(false);
  expect(b.clipped, `${label}: a word is clipped (an ellipsis)`).toEqual([]);
  // Both words share one line box: their tops agree within a pixel, and the
  // h1 is no taller than one line of its type.
  expect(Math.abs(b.wordTops[0] - b.wordTops[1]), `${label}: the words sit on two lines`).toBeLessThanOrEqual(1);
  expect(b.titleHeight, `${label}: the title is taller than one line`).toBeLessThan(b.fontSize * 1.6);
}

async function settle(page) {
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator(HEADER)).toHaveAttribute("data-nav-brand", /^(fit|tight)$/);
}

for (const theme of ["light", "dark"]) {
  test(`signed out (${theme}): the wordmark is one line or the mascot alone`, async ({ page }) => {
    await page.addInitScript((t) => { try { localStorage.setItem("theme", t); } catch (_) {} }, theme);
    const seen = {};
    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 800 });
      await page.goto("/contests");
      await settle(page);
      const b = await brand(page);
      expectOneLineOrHidden(b, `${width}px signed out ${theme}`);
      expect(b.docOverflow, `${width}px: the page scrolls sideways`).toBeLessThanOrEqual(0);
      seen[width] = b.state;
    }
    // The ends of the range are not in doubt: a 360px phone has no room for
    // the words beside the account column; a laptop has plenty.
    expect(seen[360]).toBe("tight");
    expect(seen[600]).toBe("fit");
    expect(seen[1280]).toBe("fit");
  });
}

test("signed in: the wordmark is one line or the mascot alone, and it follows a resize", async ({ page, request }) => {
  await reseed(request);
  await login(page, "navbar-brand-fit@e2e.test");
  await page.setViewportSize({ width: WIDTHS[0], height: 800 });
  await page.goto("/contests");
  for (const width of WIDTHS) {
    // A live resize, no reload: the script answers from the ResizeObserver.
    await page.setViewportSize({ width, height: 800 });
    await page.waitForTimeout(150);
    await settle(page);
    const b = await brand(page);
    expectOneLineOrHidden(b, `${width}px signed in`);
    if (b.navLeft !== null) {
      expect(b.navLeft, `${width}px: the links reach into the brand`).toBeGreaterThanOrEqual(b.linkRight);
    }
  }
});

test("a wallet chip that hydrates wider at 768 takes the words, never ellipses them", async ({ page }) => {
  await page.setViewportSize({ width: 768, height: 800 });
  await page.goto("/contests");
  await settle(page);
  // The widest chip label the store can write (wallet_signal.js).
  await page.evaluate((sel) => {
    // Inside the last item the nav draws (the wallet chip when it shows), as
    // a hydrate grows an existing item rather than adding one.
    const items = [...document.querySelector(`${sel} .nav-row nav`).children].filter((el) => el.offsetWidth > 0);
    const chip = items[items.length - 1];
    const label = document.createElement("span");
    label.className = "text-xs whitespace-nowrap";
    label.textContent = "Not declared for this ceremony";
    chip.appendChild(label);
  }, HEADER);
  await expect(page.locator(HEADER)).toHaveAttribute("data-nav-brand", "tight");
  const tight = await brand(page);
  expectOneLineOrHidden(tight, "768px with a wide chip");
  expect(tight.navLeft).toBeGreaterThanOrEqual(tight.linkRight);
  // And back: the chip narrows, the words return whole.
  await page.evaluate((sel) => {
    document.querySelectorAll(`${sel} .nav-row nav span.text-xs.whitespace-nowrap`).forEach((el) => {
      if (el.textContent === "Not declared for this ceremony") el.remove();
    });
  }, HEADER);
  await expect(page.locator(HEADER)).toHaveAttribute("data-nav-brand", "fit");
  expectOneLineOrHidden(await brand(page), "768px with the chip back");
});

test("the desktop scroll collapse still shrinks the brand and keeps the answer", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/contests");
  await settle(page);
  await expect(page.locator(HEADER)).toHaveAttribute("data-nav-timeline-on", "");
  const restWidth = await page.locator(`${HEADER} .nav-logo-link`).evaluate((el) => el.getBoundingClientRect().width);
  await page.evaluate(() => window.scrollTo(0, 600));
  await expect.poll(() => page.locator(`${HEADER} .nav-logo-link`).evaluate((el) => el.getBoundingClientRect().width))
    .toBeLessThan(restWidth - 10);
  const b = await brand(page);
  expect(b.state).toBe("fit");
  expect(b.hidden).toBe(false);
  expect(b.clipped).toEqual([]);
});
