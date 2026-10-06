const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// The notify-me form's focus and error wiring, at runtime, on BOTH surfaces
// that render it (pages/_drop_notify_form): the /turf-monster-v2 section and
// the drop-notify modal. The markup half is test/views/drop_notify_form_a11y_render_test.rb;
// this half proves Alpine really moves focus and really flips the attributes.
//
// THE FORM EXISTS ONLY BEFORE THE DROP (NextSlateDrop::DROPS_AT, 2026-10-20
// 14:00 UTC). After it, each spec returns early rather than skipping, for the
// reason e2e/turf_monster_v2.spec.js gives: a date-gated skip leaves the
// executed set and turns the lane gate red for every PR.
const DROPS_AT = Date.parse("2026-10-20T14:00:00Z");
const formIsUp = () => Date.now() < DROPS_AT - 60_000;

async function assertErrorThenSuccess(page, scope, prefix, successTestId) {
  const input = scope.locator(`#${prefix}_email`);
  const button = scope.getByRole("button", { name: "Notify me" });

  // Untouched: not invalid, described by the help line only.
  await expect(input).not.toHaveAttribute("aria-invalid");
  await expect(input).toHaveAttribute("aria-describedby", `${prefix}_help`);

  // A refused address: the field goes invalid and names the error line,
  // which is the announced region and carries the server's sentence.
  await input.fill("not-an-email");
  await button.click();
  const alert = scope.locator(`#${prefix}_error [role="alert"]`);
  await expect(alert).toContainText("valid email");
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await expect(input).toHaveAttribute("aria-describedby", `${prefix}_error ${prefix}_help`);
  const described = await input.evaluate((el) =>
    el.getAttribute("aria-describedby").split(" ").map((id) => document.getElementById(id).textContent.trim()).join(" | "));
  expect(described).toContain("valid email");

  // A good one: the form leaves, and focus lands on the success message
  // rather than on a body the form was ripped out from under.
  const answered = page.waitForResponse((res) => res.url().endsWith("/drop-signups") && res.request().method() === "POST");
  await input.fill(`e2e-a11y-${prefix}-${Date.now()}@example.com`);
  await button.click();
  expect((await answered).status()).toBe(200);
  const success = scope.locator(`[data-test="${successTestId}"]`);
  await expect(success).toBeVisible();
  await expect(success).toBeFocused();
  await expect(success).toHaveAttribute("tabindex", "-1");
}

test.describe("notify-me form accessibility", () => {
  test("the page section marks a bad address invalid, then focuses the success message", async ({ page }) => {
    await page.goto("/turf-monster-v2");
    if (!formIsUp()) {
      await expect(page.locator('[data-test="v2-live"]')).toBeVisible();
      return;
    }
    await assertErrorThenSuccess(page, page.locator('[data-test="v2-notify"]'), "drop_signup", "v2-notify-success");
  });

  // The modal opens only with no contest to enter; the seed always has open
  // ones, so hold them for this spec and release exactly those after.
  test.describe("in the drop-notify modal", () => {
    let held = [];
    test.beforeEach(async ({ request }) => {
      const res = await request.post("/test/hold_open_contests", { data: { hold: "true" } });
      held = (await res.json()).held;
    });
    test.afterEach(async ({ request }) => {
      await request.post("/test/hold_open_contests", { data: { hold: "false", slugs: held } });
    });

    test("the modal marks a bad address invalid, then focuses the success message", async ({ page }) => {
      await page.goto("/turf-monster-v2");
      const cta = page.locator('[data-test="v2-hero-cta"]');
      await expect(cta).toHaveText("Play Turf Monster");
      if (!formIsUp()) return;

      await cta.click();
      const dialog = page.getByRole("dialog", { name: "Get notified when Weeks 7-9 drops" });
      await expect(dialog).toBeVisible();
      await expect(dialog.locator('[data-test="drop-modal-title"]')).toHaveText("Weeks 7–9 drops Oct 20");
      await assertErrorThenSuccess(page, dialog.locator('[data-test="drop-modal"]'), "drop_modal", "drop-modal-success");
    });

    // AUTOFOCUS (Alex, 2026-10-06): on a fine pointer the email field takes
    // focus once the card has opened, inside the dialog's trap; Escape closes
    // it and focus goes back to the call to action that opened it.
    test("on desktop the modal focuses the email field, and closing returns focus to the CTA", async ({ page }) => {
      await page.goto("/turf-monster-v2");
      if (!formIsUp()) return;
      const cta = page.locator('[data-test="v2-hero-cta"]');
      await cta.click();
      const dialog = page.getByRole("dialog", { name: "Get notified when Weeks 7-9 drops" });
      await expect(dialog).toBeVisible();
      await expect(dialog.locator("#drop_modal_email")).toBeFocused();
      // Stacked: the button sits under a full-width field of the same height.
      const [field, button] = await Promise.all([
        dialog.locator("#drop_modal_email").boundingBox(),
        dialog.getByRole("button", { name: "Notify me" }).boundingBox(),
      ]);
      expect(button.y).toBeGreaterThan(field.y + field.height - 1);
      expect(Math.abs(button.width - field.width)).toBeLessThan(1);
      expect(Math.abs(button.height - field.height)).toBeLessThan(1);
      const placeholderFits = await dialog.locator("#drop_modal_email").evaluate((el) => {
        const probe = document.createElement("span");
        const cs = getComputedStyle(el);
        probe.style.font = cs.font; probe.style.position = "absolute"; probe.style.visibility = "hidden";
        probe.textContent = el.placeholder; document.body.appendChild(probe);
        const fits = probe.getBoundingClientRect().width <= el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
        probe.remove(); return fits;
      });
      expect(placeholderFits).toBe(true);

      await page.keyboard.press("Escape");
      await expect(dialog).toBeHidden();
      await expect(cta).toBeFocused();
    });
  });
});
