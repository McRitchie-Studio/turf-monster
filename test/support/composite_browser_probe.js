// Measure how a browser ACTUALLY alpha-composites a translucent background over
// an opaque one, and print the pixels that
// test/views/error_text_contrast_test.rb pins composite() against.
//
//   node test/support/composite_browser_probe.js
//
// WHY THIS EXISTS. The guard used to blend translucent backdrops in linear
// light; browsers alpha-composite in gamma-encoded sRGB. That was not caught by
// re-deriving the maths, because a second implementation of the same wrong model
// agrees with the first. The only witness that settles it is a rendered pixel.
// So this renders real DOM in a real browser and reads the pixel back out of a
// screenshot. The canvas is never used as a compositor, and getComputedStyle is
// reported only to show what it does NOT tell you: it returns the SPECIFIED
// rgba()/oklab() value, never the composited result.
//
// This is an instrument, not a test. It is not in the minitest suite and not in
// the Playwright e2e run (playwright.config.js pins testDir to ./e2e); it needs
// a browser the CI image does not have to install for a unit-tier guard. Run it
// by hand when a pinned value is questioned, and paste what it prints.

const zlib = require("zlib");

// Playwright is a devDependency installed at the repo root. A worktree has no
// node_modules of its own, and it does not need one: Node resolves a bare
// specifier by walking node_modules up every ancestor directory, and the root
// checkout is an ancestor of .worktrees/<slug>. Set PLAYWRIGHT_MODULE to point
// somewhere else.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

// Decode a 1x1 PNG. For the first pixel of the first row every PNG filter type
// reduces to the identity — left, up and up-left are all zero — so no filter
// reconstruction is needed and no image library is required.
function pixelOf(buf) {
  let off = 8, w, h, depth, idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); depth = data[8]; }
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    off += 12 + len;
  }
  if (w !== 1 || h !== 1) throw new Error(`expected a 1x1 clip, got ${w}x${h}`);
  if (depth !== 8) throw new Error(`expected 8 bits per channel, got ${depth}`);
  const raw = zlib.inflateSync(Buffer.concat(idat)); // [filter, R, G, B, ...]
  return "#" + [raw[1], raw[2], raw[3]].map((v) => v.toString(16).padStart(2, "0")).join("");
}

// Each case is [id, opaque backdrop, translucent tint, what it is for].
const CASES = [
  ["canonical",   "#ffffff", "rgba(255, 0, 0, 0.5)", "pinned: rgba(255,0,0,.5) over white"],
  ["red20-light", "#ffffff", "rgba(251, 44, 54, 0.2)", "pinned: bg-red-500/20 over the light card"],
  ["red10-dark",  "#3c3853", "rgba(251, 44, 54, 0.1)", "pinned: bg-red-500/10 over the dark card"],
  // Tailwind v4 emits an alpha background three ways and resolve_bg reads all
  // three. These prove the three forms composite IDENTICALLY, so reducing a
  // color-mix()/#rrggbbaa background to [colour, alpha] is sound.
  ["red10-mix",   "#3c3853", "color-mix(in oklab, #fb2c36 10%, transparent)", "same, color-mix form"],
  ["red10-hex8",  "#3c3853", "#fb2c361a", "same, #rrggbbaa form"],
  // THE PRODUCTION FORM. Tailwind v4 keeps its palette in oklch and emits an
  // alpha utility as a color-mix against that var, so an oklch tint — not a hex
  // one — is what the guard actually composites. Pinned separately for that
  // reason: a hex-only pin leaves the oklch branch of srgb_encoded unmeasured.
  ["red10-oklch", "#3c3853",
   "color-mix(in oklab, oklch(63.7% .237 25.331) 10%, transparent)", "pinned: the form Tailwind emits"],
  ["red20-oklch", "#ffffff",
   "color-mix(in oklab, oklch(63.7% .237 25.331) 20%, transparent)", "pinned: same, over the light card"],
  // Half-way channels, where rounding is decided. 127.5 resolves DOWN over a
  // light backdrop and UP over a dark one, which no single continuous rounding
  // rule reproduces: Chrome quantises alpha to 8 bits and rounds the
  // premultiplied source and destination terms separately. That asymmetry is
  // why the guard pins these two within one 8-bit step instead of exactly.
  ["half-black",  "#ffffff", "rgba(0, 0, 0, 0.5)", "rounding: 127.5 over white"],
  ["half-white",  "#000000", "rgba(255, 255, 255, 0.5)", "rounding: 127.5 over black"],
];

const html =
  `<!doctype html><meta charset="utf-8"><style>
     html,body{margin:0;padding:0;background:#808080}
     .row{display:flex}.stack{width:40px;height:40px;position:relative}
     .tint{position:absolute;inset:0}
   </style><div class="row">` +
  CASES.map(([id, bg, tint]) =>
    `<div class="stack" style="background:${bg}"><div class="tint" id="${id}" style="background:${tint}"></div></div>`
  ).join("") + `</div>`;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1, colorScheme: "light" });
  await page.setContent(html);

  console.log(`browser: Chromium ${browser.version()}\n`);
  console.log("rendered  backdrop  tint".padEnd(58) + "getComputedStyle");
  console.log("-".repeat(100));
  for (const [id, bg, tint, note] of CASES) {
    const el = page.locator("#" + id);
    const box = await el.boundingBox();
    const shot = await page.screenshot({
      clip: { x: Math.floor(box.x + box.width / 2), y: Math.floor(box.y + box.height / 2), width: 1, height: 1 },
      animations: "disabled",
    });
    const computed = await el.evaluate((e) => getComputedStyle(e).backgroundColor);
    console.log(`${pixelOf(shot)}   ${bg}   ${tint}`.padEnd(58) + computed);
    console.log(`          ${note}`);
  }
  await browser.close();
})().catch((e) => { console.error("FAILED:", e); process.exit(1); });
