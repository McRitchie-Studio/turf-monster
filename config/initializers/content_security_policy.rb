# OPSEC-041: Content-Security-Policy headers.
#
# Whitelist of asset sources to defang reflected/stored XSS. The site
# loads:
#   - Phantom wallet from injected window object (no external script)
#   - YouTube (privacy-mode) player iframe for the wallet-setup explainer video
#   - Solana web3 and tweetnacl via CDN (script-src https:)
#   - Stripe Checkout redirect (form POST to checkout.stripe.com — needs a form-action entry)
#   - Google OAuth (OmniAuth google_oauth2 form POST to accounts.google.com — needs a form-action entry)
#   - PayPal JS SDK when PAYMENT_PROVIDER=paypal (script-src :https covers the
#     SDK itself; the button + checkout/QR overlay iframes need frame-src
#     entries for *.paypal.com and *.venmo.com — added conditionally below so
#     Stripe-provider deploys serve byte-identical headers)
#   - Transactional email providers are server-side only
#
# Inline scripts/styles are used by Alpine and several inline blocks in the
# ERB layouts, so this policy allows 'unsafe-inline' on script-src/style-src.
# The signing pages narrow script-src to named hosts plus a nonce
# (SigningCsp, app/controllers/concerns/signing_csp.rb). Report-only in dev
# so we surface accidental violations without blocking; enforced in
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

  # Per-request nonce. Every inline <script> renders it; only the signing
  # pages' header carries it (SigningCsp), so nonce_directives stays empty
  # here and every other page's header is the policy above, unchanged.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = []

  # script-src on a signing page: no 'unsafe-inline', no https:, and each
  # third-party script named BY FILE, not by host. cdn.jsdelivr.net, unpkg.com
  # and cdnjs.cloudflare.com mirror every npm package, so a bare host would let
  # an injected <script src> load any of them; a path source matches only the
  # one file (each also pinned by SRI where it is loaded). Alpine, confetti,
  # sortable and leaflet are vendored in studio-engine and load from 'self'.
  #
  # 'unsafe-eval' stays while Alpine runs on these pages (engine-retires-alpine
  # removes it): Alpine evaluates every x-data, x-on and :binding with new
  # Function, and the layout's <body x-data>, the modal host and the wallet
  # modals, the avatar and banner croppers, and the contest board are Alpine
  # on every signing page. What it allows: Alpine attributes in markup that
  # reaches the page after load run. signing_document strips scripts from
  # frames and streams; Alpine attributes are not stripped.
  #
  # cdn.logr-in.com stays a host: it is LogRocket's own CDN, serving only its
  # recorder, and loads only when session replay is on.
  signing_script_src = [
    :self,
    :unsafe_eval,
    :report_sample,               # a report quotes the first 40 characters it blocked
    "https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js",       # layout, wallet_provider, solana-studio deeplink_assets
    "https://unpkg.com/@solana/web3.js@1.98.4/lib/index.iife.min.js",       # layout
    "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js", # studio/cropper_assets (avatar, contest banner)
    "https://cdn.logr-in.com"     # LogRocket
  ]
  signing_script_src << "https://www.paypal.com" if paypal_provider
  config.x.signing_csp_script_src = signing_script_src

  # THE ENFORCE SWITCH. false: a signing page enforces the policy above and
  # reports the strict one (Content-Security-Policy-Report-Only). true: it
  # enforces the strict one.
  config.x.signing_csp_enforced = false
end
