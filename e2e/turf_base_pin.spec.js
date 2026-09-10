const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// The Turf multiplier base is pinned: rank 1 always prices x1.0, and NFL
// slates climb LINEARLY to the top of the curve (soccer keeps log decay).
// Seeded values come through the sport-aware SlateMatchup.turf_score_for.
test.describe("turf score pinned base", () => {
  test("NFL slate rank one shows x1.0 and the top rank caps at x2.0", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-week-1");

    const rows = page.locator("div.sortable-item");
    await expect(rows).toHaveCount(32);
    await expect(rows.first()).toContainText("1.0x");
    await expect(rows.last()).toContainText("2.0x");

    // Linear midpoint: rank 17 of 32 sits near the curve's middle (~1.5x),
    // which the old log curve would have pushed well past 2.6x.
    await expect(rows.nth(16)).toContainText("1.5x");

    // Chart shape: no Goals series on football, the Turf axis is reversed so
    // x1.0 sits at the top, the DK axis shrinks to the data, and turf 1.0 is
    // pixel-anchored to the DK maximum — both lines leave the same point.
    const chartShape = await page.evaluate(() => {
      const chart = Chart.getChart(document.getElementById("formulaCurvesChart"));
      const dkVals = chart.data.datasets.find((d) => d.label === "DK Expectation").data;
      const dkMax = Math.max(...dkVals);
      return {
        labels: chart.data.datasets.map((d) => d.label),
        reversed: chart.options.scales.y.reverse,
        dkAxisMin: chart.options.scales.y2.min,
        anchorGapPx: Math.abs(chart.scales.y.getPixelForValue(1.0) - chart.scales.y2.getPixelForValue(dkMax)),
      };
    });
    expect(chartShape.labels).toEqual(["Turf Score", "DK Expectation"]);
    expect(chartShape.reversed).toBe(true);
    expect(chartShape.dkAxisMin).toBeGreaterThan(0); // window shrunk to data
    expect(chartShape.anchorGapPx).toBeLessThan(1); // shared starting point
  });
});
