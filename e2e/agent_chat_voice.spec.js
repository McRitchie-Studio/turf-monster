const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");

// [e2e] Hold to talk on /chat, admins only (/tasks/turf-chat-takes-voice;
// docs/AGENT_CHAT.md). Everything is real but the ends: the take goes through the
// engine's POST /voice/takes to the MOCK transcriber, and the words go through the
// app's proxy and the engine's client to a contract stub on a real socket
// (test/support/agent_chat_contract_hub.rb, in the server's process).
//
// FORGERY IS ON. The test environment turns it off, and POST /test/agent_chat_lab
// turns it back on for the page and both calls, with production's per-form tokens.
// A take once carried the form's token and was green only with forgery off.
//
// THE MICROPHONE IS STUBBED before any page script runs, as the engine's own spec
// does: a Web Audio oscillator. A real microphone is out of reach here.
//
// CONTROLS, each run against this file:
//   - render the chat with no `voice: true`: the hold specs fail waiting for the button.
//   - drop agent_chat_allowed from the initializer: the player spec fails at the 403.
//   - blank the initializer's site_footer_chat_path: the admin spec fails at the footer.

const PAGE = "/chat";
const CHAT = '[data-test="agent-chat"]';
const MIC = '[data-test="agent-chat-voice"]';
const STATUS = '[data-test="agent-chat-voice-status"]';
const RECORDER = "[data-studio-controller='voice-recorder']";
const FOOTER_CHAT = 'footer[data-site-footer] a[href="/chat"]';
const MOCK_TEXT = "This is a mock transcript of your voice.";
const PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio.";
const PLAYER = "mason@mcritchie.studio";

test.use({ viewport: { width: 390, height: 844 } });

async function stubMicrophone(page) {
  await page.addInitScript(() => {
    const mic = { deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" };
    const granted = () => sessionStorage.getItem("stub-mic-granted") === "1";
    const media = navigator.mediaDevices;
    media.enumerateDevices = async () => [{
      kind: "audioinput", groupId: "", deviceId: granted() ? mic.deviceId : "", label: granted() ? mic.label : "",
    }];
    let source = null;
    media.getUserMedia = async () => {
      sessionStorage.setItem("stub-mic-granted", "1");
      if (!source) {
        const context = new AudioContext();
        const oscillator = context.createOscillator();
        oscillator.frequency.value = 220;
        const volume = context.createGain();
        oscillator.connect(volume);
        oscillator.start();
        source = { context, volume };
      }
      if (source.context.state === "suspended") await source.context.resume();
      source.volume.gain.value = 0.3;
      const out = source.context.createMediaStreamDestination();
      source.volume.connect(out);
      const track = out.stream.getAudioTracks()[0];
      Object.defineProperty(track, "label", { value: mic.label });
      track.getSettings = () => ({ deviceId: mic.deviceId });
      return out.stream;
    };
  });
}

// A report-only policy still fires this event, so the test environment sees what
// production's enforced policy would refuse.
async function watchCsp(page) {
  await page.addInitScript(() => {
    window.cspViolations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      window.cspViolations.push(`${event.effectiveDirective} ${event.blockedURI}`);
    });
  });
}

async function hubLog(request) {
  return (await request.get("/test/agent_chat_lab")).json();
}

// The page's token, from a page this browser may open, for a direct call.
async function pageToken(page) {
  return page.locator("meta[name='csrf-token']").getAttribute("content");
}

async function holdToTalk(page) {
  const recorder = page.locator(RECORDER);
  const box = await recorder.locator("[data-voice-recorder-button]").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(recorder).toHaveAttribute("data-voice-recorder-state", "recording");
  await page.waitForTimeout(700);
  await page.mouse.up();
  await expect(recorder).not.toHaveAttribute("data-voice-recorder-state", /recording|starting/);
}

const sideways = (page) => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

test.describe.serial("/chat with forgery on, through the proxy, to a stub hub", () => {
  test.beforeAll(async ({ request }) => {
    await reseed(request);
    const on = await request.post("/test/agent_chat_lab", { data: { on: true } });
    expect(on.ok()).toBe(true);
  });

  test.afterAll(async ({ request }) => {
    await request.post("/test/agent_chat_lab", { data: { on: false } });
  });

  for (const theme of ["light", "dark"]) {
    test(`an admin holds to talk at 390px, and Turf answers (${theme})`, async ({ page, request }, testInfo) => {
      await page.addInitScript((value) => localStorage.setItem("theme", value), theme);
      await stubMicrophone(page);
      await watchCsp(page);
      const before = (await hubLog(request)).messages.length;

      await loginAdmin(page);
      await page.goto(PAGE);
      await expect(page.locator(CHAT)).toHaveAttribute("data-agent-chat-ready", "true");
      await expect(page.locator(RECORDER)).toHaveAttribute("data-voice-recorder-ready", "true");
      await expect(page.locator("html")).toHaveClass(new RegExp(theme === "dark" ? "dark" : "^(?!.*dark)"));
      await expect(page.locator('[data-test="agent-chat-voice-privacy"]')).toHaveText(PRIVACY);
      await expect(page.locator(`form[data-test="agent-chat-form"] ${MIC} ${RECORDER}`)).toHaveCount(1);

      const takeTokens = [];
      const sent = [];
      page.on("request", (r) => {
        if (r.method() !== "POST") return;
        if (r.url().endsWith("/voice/takes")) takeTokens.push(r.headers()["x-csrf-token"]);
        if (r.url().endsWith("/agent_chat/messages")) sent.push(r.postDataJSON());
      });

      await holdToTalk(page);

      // "sent" means the real forgery check passed, on both calls.
      await expect(page.locator(MIC)).toHaveAttribute("data-agent-chat-voice-state", "sent");
      await expect(page.locator(STATUS)).toHaveText("Sent. Spoken by Someone new.");
      expect(takeTokens).toEqual([await pageToken(page)]);
      await expect(page.locator('[data-test="agent-chat-messages"]').getByText(`You said: ${MOCK_TEXT}`).last()).toBeVisible();

      expect(sent).toHaveLength(1);
      expect(Object.keys(sent[0].voice).sort()).toEqual(["check", "duration_ms", "score"]);

      // What the hub received: the verified owner, Turf's soul, a measurement and no name.
      const { messages } = await hubLog(request);
      expect(messages).toHaveLength(before + 1);
      const row = messages[messages.length - 1];
      expect(row.soul).toBe("turf_monster");
      expect(row.text).toBe(MOCK_TEXT);
      expect(row.person).toEqual({ email: "alex@mcritchie.studio" });
      expect(Object.keys(row.voice).sort()).toEqual(["check", "duration_ms", "score"]);

      expect(await sideways(page)).toBeLessThanOrEqual(0);
      expect(await page.evaluate(() => window.cspViolations)).toEqual([]);

      await expect(page.locator(FOOTER_CHAT)).toHaveCount(1);
      await page.screenshot({ path: testInfo.outputPath(`chat-${theme}.png`), fullPage: true });
    });
  }

  test("a player gets no link and a refusal from both calls before any hub call", async ({ page, request }) => {
    await login(page, PLAYER, "password");
    await page.goto("/about");
    await expect(page.locator("footer[data-site-footer]")).toHaveCount(1);
    await expect(page.locator(FOOTER_CHAT)).toHaveCount(0);
    const token = await pageToken(page);
    const before = (await hubLog(request)).requests.length;

    const chat = await page.request.post("/agent_chat/messages", {
      headers: { "X-CSRF-Token": token, Accept: "application/json" }, data: { soul: "turf_monster", text: "Hi" },
    });
    expect(chat.status()).toBe(403);
    expect((await chat.json()).reason).toBe("not_allowed");

    const take = await page.request.post("/voice/takes", {
      headers: { "X-CSRF-Token": token, Accept: "application/json" },
      multipart: { "voice[audio]": { name: "take", mimeType: "audio/webm", buffer: Buffer.from("audio") }, "voice[duration_ms]": "900" },
    });
    expect(take.status()).toBe(403);
    expect((await take.json()).reason).toBe("not_allowed");

    const away = await page.goto(PAGE);
    expect(new URL(away.url()).pathname).not.toBe(PAGE);
    await expect(page.locator(CHAT)).toHaveCount(0);

    expect((await hubLog(request)).requests.length).toBe(before);
  });

  test("a signed-out visitor gets no link and a refusal from both calls before any hub call", async ({ page, request }) => {
    await page.goto("/about");
    await expect(page.locator(FOOTER_CHAT)).toHaveCount(0);
    const token = await pageToken(page);
    const before = (await hubLog(request)).requests.length;

    const chat = await page.request.post("/agent_chat/messages", {
      headers: { "X-CSRF-Token": token, Accept: "application/json" }, data: { soul: "turf_monster", text: "Hi" },
    });
    expect(chat.status()).toBe(403);

    const take = await page.request.post("/voice/takes", {
      headers: { "X-CSRF-Token": token, Accept: "application/json" },
      multipart: { "voice[audio]": { name: "take", mimeType: "audio/webm", buffer: Buffer.from("audio") }, "voice[duration_ms]": "900" },
    });
    expect(take.status()).toBe(401);

    expect((await hubLog(request)).requests.length).toBe(before);
  });
});
