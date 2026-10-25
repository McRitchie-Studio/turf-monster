// The request wrappers this app lends to studio-engine's cards, by export name.
//
// The engine pins "studio/host_fetchers" to an empty module; config/importmap.rb
// pins the same name here, and the host's pin wins. A card that names a fetcher
// (the newsletter cards: fetcher "authedFetch") imports this module on the first
// press that needs it, never at boot. studio-engine's studio/newsletter_modal.js
// holds the contract: the fetcher takes fetch's arguments and returns a Response,
// or null when it answered the request itself.
//
// authedFetch opens the sign-in card on a 401 and the rate-limit card on a 429,
// and returns null for both.
export { authedFetch } from "solana_utils"
