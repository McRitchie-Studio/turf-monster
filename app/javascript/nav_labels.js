// THE NAVBAR NAMES ITS OWN CONTROLS (/tasks/turf-navbar-polish).
//
// Two things the engine's markup leaves to the host, done here rather than by
// forking an engine partial back into this app (the de-fork program took
// components/_theme_toggle out of Turf, and this keeps it out):
//
// 1. THE THEME TOGGLE. studio-engine's components/_theme_toggle renders an
//    icon-only <button> with no type and no aria-label, twice per page (the
//    desktop icon rail and the phone row, both through _theme_toggle_morph).
//    Its title gives it a name of last resort, which a screen reader may read
//    as a description or not at all, and nothing says which theme is on. Each
//    one gets type="button", aria-label="Dark theme" and aria-pressed tracking
//    the root's `dark` class: the toggle-button pattern, a fixed name and the
//    state beside it.
//
// 2. THE TRUNCATED NAME. From 768px the name (Studio.navbar_name_in_rows,
//    [data-nav-name-trigger]) ellipsizes inside its 7rem cap, so a long name
//    shows as "Christopher_Mo…". Its control gets the full name as its title,
//    so a pointer user can read it on hover. Its accessible name was always
//    the full text; only the pixels truncate.
//
// The engine owns this markup; when it ships the attributes itself, this file
// goes. It only adds attributes, never moves or restyles anything, so the
// account-column sizes nav_band_watch.js observes never change because of it.

export const THEME_TOGGLES = ".nav-toggle-icon > button"
export const NAME_TRIGGERS = "[data-nav-name-trigger]"

export function labelThemeToggles(scope, isDark) {
  scope.querySelectorAll(THEME_TOGGLES).forEach((button) => {
    if (!button.getAttribute("type")) button.setAttribute("type", "button")
    button.setAttribute("aria-label", "Dark theme")
    button.setAttribute("aria-pressed", isDark ? "true" : "false")
  })
}

export function titleNames(scope) {
  scope.querySelectorAll(NAME_TRIGGERS).forEach((trigger) => {
    const name = trigger.querySelector("[data-nav-name]")
    const text = name && name.textContent.replace(/\s+/g, " ").trim()
    if (text) trigger.setAttribute("title", text)
  })
}

let themeObserver = null

function isDark() {
  return document.documentElement.classList.contains("dark")
}

function label() {
  labelThemeToggles(document, isDark())
  titleNames(document)
}

function install() {
  label()
  if (themeObserver || typeof MutationObserver !== "function") return
  // The toggle flips the root's `dark` class (studio/alpine_stores.js
  // toggleTheme), and so does a theme set from anywhere else.
  themeObserver = new MutationObserver(() => labelThemeToggles(document, isDark()))
  themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
}

if (typeof document !== "undefined" && document.addEventListener) {
  document.addEventListener("turbo:load", install)
}
