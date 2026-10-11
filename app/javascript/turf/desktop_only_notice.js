// The rule behind the desktop-only-notice controller. No DOM.

// What the notice shows, asked of window.walletProvider (`provider`). Only a
// phone sees it, and its sentence comes from the provider, the same source as
// the error a press would throw.
export function noticeFor(provider) {
  if (!provider || typeof provider.isMobile !== "function" || !provider.isMobile()) {
    return { show: false, message: null }
  }
  const message = typeof provider.desktopOnlyMessage === "function" ? provider.desktopOnlyMessage() : null
  return { show: true, message }
}
