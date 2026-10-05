const { test, expect } = require("@playwright/test");

// [e2e] The "Turf Monster" logotype paints the brand green in both themes.
//
// WHY THIS NEEDS A BROWSER. test/views/wordmark_brand_green_test.rb reads the
// compiled stylesheet and proves a rule EXISTS that paints the logotype from
// --tm-wordmark. It cannot prove that rule WINS, and for the footer that is
// the whole question: the footer is studio-engine markup, and the engine
// colours `.ftr-wordmark-accent` from an inline <style> block that sits later
// in the document than this app's stylesheet. Equal specificity would lose to
// it and leave the footer in the darker primary, with every server-side
// assertion still green. Only the computed colour says who won.
//
// THE OTHER HALF IS WHAT DID NOT MOVE. The logotype was repainted by the
// 2026-09-16 contrast fix as a side effect, and this change must not undo that
// fix on the way back. So each theme also reads a green text link (the primary
// ink), the primary button's fill, and a footer link on hover (which shares the
// engine variable the accent word used to read).

const BRAND_GREEN = "rgb(75, 175, 80)"; //   #4BAF50, the logotype
const PRIMARY_FILL = "rgb(46, 125, 50)"; //  #2E7D32, buttons and fills
const DARK_INK = "rgb(129, 199, 132)"; //    #81C784, green text on the dark theme

const THEMES = {
  dark: { ink: DARK_INK },
  light: { ink: PRIMARY_FILL },
};

for (const [theme, { ink }] of Object.entries(THEMES)) {
  test(`the logotype is brand green in the ${theme} theme, and the primary is untouched`, async ({ page }) => {
    // The layout's head script reads this before first paint.
    await page.addInitScript((t) => localStorage.setItem("theme", t), theme);
    await page.goto("/contact");

    await expect(page.locator("html")).toHaveClass(theme === "dark" ? /(^|\s)dark(\s|$)/ : /^(?!.*\bdark\b)/);

    // The logotype, in the navbar and in the engine footer.
    const navWord = page.locator("header .nav-title span", { hasText: "Monster" });
    const footerWord = page.locator("footer.ftr .ftr-wordmark-accent");
    await expect(navWord).toHaveText("Monster");
    await expect(footerWord).toHaveText("Monster");
    await expect(navWord).toHaveCSS("color", BRAND_GREEN);
    await expect(footerWord).toHaveCSS("color", BRAND_GREEN);

    // Not moved: green TEXT still reads the per-theme ink...
    await expect(page.locator('main a.text-primary[href^="mailto:"]').first()).toHaveCSS("color", ink);
    // ...the primary button still wears the darker fill under its white label...
    const signIn = page.locator("header a.btn-primary", { hasText: "Sign in" }).first();
    await expect(signIn).toHaveCSS("background-color", PRIMARY_FILL);
    await expect(signIn).toHaveCSS("color", "rgb(255, 255, 255)");
    // ...and a footer link still hovers to the engine's own primary, which is
    // the variable the accent word would have dragged along had it been set.
    const footerLink = page.locator('footer.ftr a.ftr-link[href="/contests"]').first();
    await footerLink.scrollIntoViewIfNeeded();
    await footerLink.hover();
    await expect(footerLink).toHaveCSS("color", PRIMARY_FILL);
  });
}
