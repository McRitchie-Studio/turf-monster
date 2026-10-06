const { test, expect } = require("@playwright/test");
const { reseed, loginAdmin } = require("./helpers");

// [e2e] /admin/drop_signups/announcement — the manual drop email.
//
// The admin opens the preview, reads the exact recipient count, types it back,
// (before the drop) ticks "Send early", confirms the browser dialog, and reads
// the result counts. The server's guards are pinned in
// test/controllers/admin/drop_announcement_test.rb; what only a browser can
// prove is the Alpine wiring that keeps Send disabled until the typed count
// matches (and, before the drop, until "Send early" is ticked) and the confirm
// dialog in front of an action with no undo.
//
// Deliveries: the e2e server runs RAILS_ENV=test, so the outbox rows are
// written and nothing is ever handed to a mail server.
//
// The database is shared across specs and never rebuilt, so the spec never
// assumes a count: it seeds two owed addresses, reads whatever total the page
// shows, and asserts against that.
test.beforeEach(async ({ request }) => await reseed(request));

test("admin previews, confirms the count, sends, and sees the result", async ({ page }) => {
  const stamp = Date.now();
  const seeded = await page.request.post("/test/seed_drop_signups", {
    form: { "emails[]": `e2e-drop-a-${stamp}@example.com` },
  });
  expect(seeded.ok()).toBeTruthy();
  await page.request.post("/test/seed_drop_signups", { form: { "emails[]": `e2e-drop-b-${stamp}@example.com` } });

  await loginAdmin(page);
  await page.goto("/admin/drop_signups");
  await page.locator('[data-test="drop-signups-announce"]').click();
  await expect(page.locator('[data-test="admin-drop-announcement"]')).toBeVisible();

  // All four rendered emails are on the page.
  for (const id of ["announcement-new_player", "announcement-existing_player", "confirmation-new_player", "confirmation-existing_player"]) {
    await expect(page.locator(`[data-test="announcement-preview-${id}"]`)).toBeVisible();
  }
  const preview = page.frameLocator('[data-test="announcement-preview-announcement-new_player"]');
  await expect(preview.locator("body")).toContainText("is live");
  await expect(preview.locator('[data-test="drop-email-unsubscribe"]')).toBeVisible();

  const count = Number((await page.locator('[data-test="announcement-recipient-count"]').innerText()).replace(/,/g, ""));
  expect(count).toBeGreaterThanOrEqual(2);
  const claimedBefore = Number(await page.locator('[data-test="announcement-claimed"]').innerText());

  const send = page.locator('[data-test="announcement-send"]');
  await expect(send).toBeDisabled();
  await page.locator('[data-test="announcement-confirm-count"]').fill(String(count + 1));
  await expect(send).toBeDisabled();
  await page.locator('[data-test="announcement-confirm-count"]').fill(String(count));

  // Before the drop the button also waits for "Send early"; after it, there is
  // no such box. The server drew whichever is true, and the spec follows it.
  const early = page.locator('[data-test="announcement-send-early"]');
  if (await early.count()) {
    await expect(send).toBeDisabled();
    await early.check();
  }
  await expect(send).toBeEnabled();

  let dialogText = "";
  page.once("dialog", async (dialog) => {
    dialogText = dialog.message();
    await dialog.accept();
  });
  await send.click();

  await expect(page.locator("body")).toContainText(`Queued the announcement for ${count}`);
  expect(dialogText).toContain(String(count));
  await expect(page.locator('[data-test="announcement-recipient-count"]')).toHaveText("0");
  await expect(page.locator('[data-test="announcement-claimed"]')).toHaveText(String(claimedBefore + count));
  const queued = Number(await page.locator('[data-test="announcement-queued"]').innerText());
  const sent = Number(await page.locator('[data-test="announcement-sent"]').innerText());
  expect(queued + sent).toBeGreaterThanOrEqual(count);
  await expect(send).toBeDisabled();
});
