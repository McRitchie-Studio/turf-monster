# OPSEC-041: Content-Security-Policy headers.
#
# Whitelist of asset sources to defang reflected/stored XSS. The site
# loads:
#   - Phantom wallet from injected window object (no external script)
#   - YouTube (privacy-mode) player iframe for the wallet-setup explainer video
#   - Solana web3 + Alpine via CDN (script-src https:)
#   - Stripe Checkout redirect (form POST to checkout.stripe.com — needs a form-action entry)
#   - Google OAuth (OmniAuth google_oauth2 form POST to accounts.google.com — needs a form-action entry)
#   - PayPal JS SDK when PAYMENT_PROVIDER=paypal (script-src :https covers the
#     SDK itself; the button + checkout/QR overlay iframes need frame-src
#     entries for *.paypal.com and *.venmo.com — added conditionally below so
#     Stripe-provider deploys serve byte-identical headers)
#   - Transactional email providers are server-side only
#
# Inline scripts/styles are used by Alpine and several inline blocks in the
# ERB layouts. Rails 7's `:strict_dynamic` + nonce approach would be ideal
# but requires a refactor of inline script use. For v1 we allow 'unsafe-inline'
# on script-src/style-src — narrowed via nonce in a follow-up. Report-only
# in dev so we surface accidental violations without blocking; enforced in
# production.

Rails.application.configure do
  # ENV read directly (not Payments / config.x.payment_provider): initializers
  # run alphabetically, so paypal.rb hasn't resolved the flag yet when this
  # file executes. Same normalization as paypal.rb.
  paypal_provider = (ENV["PAYMENT_PROVIDER"].presence || "none").to_s.strip.downcase == "paypal"
  # youtube-nocookie serves the player the wallet-setup modal plays inline (the
  # "New to Solana Wallets?" explainer); youtube.com is listed with it because
  # the nocookie player hands some requests back to the main host mid-playback,
  # and a frame-src miss there is a black box with no error the user can act on.
  frame_sources = [
    :self,
    "https://js.stripe.com",
    "https://hooks.stripe.com",
    "https://www.youtube-nocookie.com",
    "https://www.youtube.com"
  ]
  frame_sources += ["https://*.paypal.com", "https://*.venmo.com"] if paypal_provider

  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data, :blob
    policy.object_src  :none
    policy.script_src  :self, :https, :unsafe_inline, :unsafe_eval
    policy.style_src   :self, :https, :unsafe_inline
    policy.connect_src :self, :https, :wss   # XHR + Solana RPC + websockets
    policy.worker_src  :self, :blob          # canvas-confetti + LogRocket spawn Web Workers from blob: URLs (default_src has no blob → blocked in prod)
    policy.frame_src(*frame_sources)
    # Clickjacking protection: nothing here may be framed. ONE deliberate
    # exception, declared at the controller rather than widened here —
    # WalletProbeController relaxes this to :self for its own empty page, which
    # the wallet-setup modal frames to detect a just-installed Phantom without
    # reloading the page the user is on.
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self, "https://checkout.stripe.com", "https://accounts.google.com"
  end

  config.content_security_policy_report_only = !Rails.env.production?
end
