// The rules behind the referral-share controller: the copy button and the info
// popover. No DOM.

// How long the button says "Copied!".
export const COPIED_MS = 1500

// The copy button's colour: secondary while it says "Copied!", primary at rest.
export function copyButtonClasses(copied) {
  return copied ? { add: "btn-secondary", remove: "btn-primary" } : { add: "btn-primary", remove: "btn-secondary" }
}

// A click anywhere closes an open popover, except one inside it or on the
// button that toggles it (that button toggles it itself).
export function closesPopover({ open, insidePopover, onToggle }) {
  return open && !insidePopover && !onToggle
}
