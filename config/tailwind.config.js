const execSync = require('child_process').execSync
const studioPath = execSync('bundle show studio-engine').toString().trim()

// Shared color palette from studio engine
const studioColors = require(`${studioPath}/tailwind/studio.tailwind.config.js`)

// Safelist all shades of custom brand colors so they're never purged
const brandColors = ['mint', 'navy', 'violet', 'primary', 'warning']
const shades = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900]
const utilities = ['bg', 'text', 'border', 'ring']
const opacities = [10, 20, 30, 50]
const safelist = brandColors.flatMap(color => [
  // DEFAULT (no shade): bg-primary, text-primary, border-primary
  ...utilities.map(util => `${util}-${color}`),
  // DEFAULT with opacity: bg-primary/10, border-primary/30, etc.
  ...utilities.flatMap(util => opacities.map(op => `${util}-${color}/${op}`)),
  // Shaded: bg-primary-600, text-primary-700, etc.
  ...shades.flatMap(shade =>
    utilities.map(util => `${util}-${color}-${shade}`)
  ),
  // Shaded with opacity: bg-primary-900/30, border-primary-700/30, etc.
  ...shades.flatMap(shade =>
    utilities.flatMap(util => opacities.map(op => `${util}-${color}-${shade}/${op}`))
  ),
])

// Level badge variants — referenced via `level-badge-<%= lvl %>` so Tailwind's
// content scanner can't see them statically. CSS lives in
// app/assets/tailwind/application.css under "── Level Badges ──".
for (let i = 1; i <= 10; i++) safelist.push(`level-badge-${i}`)
;['classic-5', 'classic-6'].forEach(v => safelist.push(`level-badge-${v}`))

module.exports = {
  darkMode: 'class',
  content: [
    './app/views/**/*.{erb,html}',
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    `${studioPath}/app/views/**/*.{erb,html}`,
  ],
  safelist,
  theme: {
    ...studioColors.theme,
    extend: {
      ...studioColors.theme.extend,
      // Named breakpoints that capture a *semantic* layout boundary, not a
      // device class. Use these when the boundary is driven by a layout
      // constraint (a card's column width gating which content fits) rather
      // than "phone vs tablet" — that's what `sm` / `md` / `lg` are for.
      //
      // - pill-narrow (530px): smallest viewport that gives a Your Entries
      //   pill cell enough room for emoji + 3-letter team code. Below this
      //   the labels are suppressed (emoji only). Paired with `md:hidden
      //   lg:inline` to also hide labels in the md half-width-card range.
      screens: {
        ...(studioColors.theme.extend.screens || {}),
        'pill-narrow': '530px',
      },
      // `text-primary` paints the primary INK, not the primary FILL. The brand
      // primary #2E7D32 is dark enough for white button labels, but as text on
      // the dark theme it measures 2.18:1 on a card. --color-primary-ink is
      // #81C784 in the dark theme and the primary itself in the light theme
      // (declared in app/assets/tailwind/application.css). Only the DEFAULT is
      // rerouted; the shades stay the fill scale so text-primary-300 and
      // text-primary-600 still compile. bg-/border-/ring-primary keep `colors`.
      // Guard: test/views/primary_text_contrast_test.rb.
      textColor: {
        ...studioColors.theme.extend.textColor,
        primary: {
          ...studioColors.theme.extend.colors.primary,
          DEFAULT: 'rgb(var(--color-primary-ink-rgb) / <alpha-value>)',
        },
      },
      colors: {
        ...studioColors.theme.extend.colors,
        // primary palette is now dynamic from shared studio config (CSS vars)
        warning: {
          DEFAULT: '#FF7C47',
          50:  '#fff3ed',
          100: '#ffe2d1',
          200: '#ffc9a8',
          300: '#ffaa74',
          400: '#FF7C47',
          500: '#FF7C47',
          600: '#e5603a',
          700: '#cc4a2d',
          800: '#a33a24',
          900: '#7a2c1c',
        },
      },
    },
  },
}
