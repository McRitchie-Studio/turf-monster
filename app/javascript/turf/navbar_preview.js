// The frame and button state behind the navbar-preview controller. No DOM.

export const SCROLLED_CLASSES = [ "bg-primary", "text-white" ]
export const UNSCROLLED_CLASSES = [ "bg-surface-alt", "text-secondary", "hover:text-heading" ]

// The width label, the frame's inline style, and the Scrolled button's
// classes for a preview `width` pixels wide.
export function previewState(width, scrolled) {
  return {
    label: `${width}px`,
    width: `${width}px`,
    navP: scrolled ? "1" : "0",
    add: scrolled ? SCROLLED_CLASSES : UNSCROLLED_CLASSES,
    remove: scrolled ? UNSCROLLED_CLASSES : SCROLLED_CLASSES
  }
}
