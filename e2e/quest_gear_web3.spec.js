// Quests via the gear sidebar's LEAD LINE — web3 (Phantom, no email) user.
//
// The gear panel leads with a status line built from User#next_quest
// (components/_gear_sidebar). The username and newsletter rungs OPEN THEIR
// MODALS straight from that line — the same modals the /account buttons open;
// join / chat link the contest instead. This spec drives the two MODAL-opening
// rungs and confirms the web3 add-email field on the newsletter one.
//
// IT CLICKS THE LEAD LINE, NOT A BODY ROW. It used to click "Pick a username"
// and "Join newsletter" rows in the panel's nav. Those rows are gone: each was a
// second copy of this same line, on the same condition, to the same
// destination, so the panel showed every nudge twice. The nav carries no
// next_quest row at all now, and [data-gear-status-quest] is the one quest
// surface. GearSidebarStatusTest pins that at the component tier; this spec
// pins that the surviving line really opens the modal.
//
// quest_step is staged server-side (setQuestState) rather than driven through
// the on-chain username/chat quests, so the lead renders the exact rung we
// want. We only OPEN the modals here (no submit), so no endpoint stubs are
// needed.

const { test, expect } = require("@playwright/test");
const {
  loginViaPhantom,
  setupPhantomMock,
  reseed,
  createActiveEntry,
  setQuestState,
} = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";

test.beforeEach(async ({ request }) => await reseed(request));

// Non-admin users get the gear titled "Settings"; open the visible (desktop)
// one. There can be a duplicate gear in the mobile sub-navbar (hidden at the
// default desktop viewport), so scope to :visible.
async function openGear(page) {
  await page.locator('button[title="Settings"]:visible').first().click();
}

// The lead line, in whichever panel is visible at this viewport. The status
// line renders into BOTH the desktop and the mobile panel — two independent
// Alpine scopes — so :visible is what picks the one on screen.
function questLead(page) {
  return page.locator('[data-gear-status-quest="true"]:visible').first();
}

test("the gear lead line opens the username modal", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  // With an entry, next_quest advances from :join to :username (fresh user).
  await createActiveEntry(page, CONTEST_SLUG);
  await page.goto("/account");

  await openGear(page);
  await expect(questLead(page)).toHaveText(/Quest: Customize Username/);
  await questLead(page).click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Change Username")).toBeVisible();
  await expect(dialog.getByPlaceholder("username")).toBeVisible();
});

test("the gear lead line opens the newsletter modal with the add-email field", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  await createActiveEntry(page, CONTEST_SLUG);
  // Stage past username + chat so next_quest === :newsletter (the rung whose
  // lead line opens the newsletter-subscribe modal). Reload so the server
  // re-renders the panel with the new pointer.
  await setQuestState(page, { username_changed: true, chat_sent: true });
  await page.goto("/account");

  await openGear(page);
  await expect(questLead(page)).toHaveText(/Quest: Join the Newsletter/);
  await questLead(page).click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Join the Newsletter")).toBeVisible();
  // web3 (no email on file) -> the add-email capture field is present.
  await expect(dialog.getByPlaceholder("you@example.com")).toBeVisible();
});
