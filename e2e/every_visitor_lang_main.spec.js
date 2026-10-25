const path = require("path");
const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// EVERY VISITOR GETS A LANGUAGE AND A MAIN LANDMARK (task:
// turf-every-visitor-lang-main-cache; audit 2026-10-24, lane UI P1).
//
// The audit ran axe-core against production and found html-has-lang and
// landmark-one-main on every Turf page that uses the app layout. The view tier
// (test/views/every_visitor_lang_main_test.rb) pins the markup; this is the
// same two rules read by axe itself in a real browser, because axe is what
// failed and a rendered-HTML assertion is only our reading of what axe wants.
//
// Only those two rules run. The audit's wider axe findings are other cards, and
// a spec that failed on any of them would be red for reasons this task does not
// own. Both widths the audit measured, logged out, as a first visit sees them.
const AXE = path.join(__dirname, "..", "node_modules", "axe-core", "axe.min.js");
const RULES = ["html-has-lang", "landmark-one-main"];
const PAGES = ["/", "/contests", "/getting-started"];

test.beforeEach(async ({ request }) => await reseed(request));

for (const width of [1280, 390]) {
  test.describe(`at ${width}px`, () => {
    test.use({ viewport: { width, height: 900 } });

    for (const url of PAGES) {
      test(`${url} passes axe html-has-lang and landmark-one-main`, async ({ page }) => {
        const response = await page.goto(url);
        expect(response.status()).toBe(200);

        await page.addScriptTag({ path: AXE });
        const result = await page.evaluate(async (rules) => {
          const r = await window.axe.run(document, { runOnly: { type: "rule", values: rules } });
          return {
            ran: r.passes.concat(r.violations, r.incomplete).map((x) => x.id),
            violations: r.violations.map((v) => `${v.id}: ${v.nodes.length} node(s)`),
          };
        }, RULES);

        // The premise: both rules actually ran. axe drops a rule it finds
        // inapplicable, and an empty violation list from no rules is vacuous.
        expect(result.ran.sort()).toEqual([...RULES].sort());
        expect(result.violations).toEqual([]);
      });
    }
  });
}
