module OnrampHelper
  # TRUE only when the host layout has actually REGISTERED the cdp-ramp modal,
  # so a surface may hand a click off to it.
  #
  # This is the SINGLE statement of that guard: layouts/application.html.erb
  # wraps the cdp-ramp <template x-if> in this predicate, and every surface that
  # opens 'cdp-ramp' asks the same question. Both halves matter, and each was a
  # live way to ship a button that swaps to a modal id the host never
  # registered — a click that opens an empty card, raising nothing:
  #
  #   - AppFlags.cdp_ramp? carries NO env exemption, while onramp_rail_visible?
  #     below reveals every rail outside production. So any non-production env
  #     with ENABLE_CDP_RAMP unset (dev, and the whole test suite) drew a live
  #     Coinbase rail whose modal was never registered.
  #   - logged_in? gates the cdp-ramp registration in the layout, but
  #     wallet-topup and onramp-hub are registered UNGATED there on purpose:
  #     they must survive an in-session signup, where the server-rendered
  #     logged_in? was still false. On exactly that page the Coinbase rail
  #     rendered while cdp-ramp did not — the "opened empty" report of
  #     2026-09-06 — even with the flag ON in production.
  #
  # Keep this mirroring the layout. An opener that asks a WIDER question than
  # the registration is the whole defect class.
  def cdp_ramp_modal_available?
    logged_in? && AppFlags.cdp_ramp?
  end

  # Visibility gate for an individual onramp rail in the "Add Funds" hub
  # (modals/_onramp_hub) and the Top Up Wallet modal (modals/_wallet_topup).
  # Policy: show EVERY rail locally (dev/test) so the whole hub is always
  # exercisable, but in PRODUCTION reveal each rail only when its own backend is
  # actually live. That keeps a half-wired rail (the placeholder PayPal/Venmo)
  # from shipping a dead button to real users, while leaving the full set
  # visible for design review and tests.
  #
  #   :coinbase        -> cdp_ramp_modal_available?   (EVERY env; see above)
  #   :coinflow        -> AppFlags.coinflow?          (ENABLE_COINFLOW)
  #   :aeropay         -> AppFlags.aeropay?           (ENABLE_AEROPAY)
  #   :paypal, :venmo  -> Payments.paypal_checkout?   (provider + credentials)
  #   :stripe          -> Payments.stripe?            (provider + key enabled)
  def onramp_rail_visible?(rail)
    # Coinbase is the one rail whose destination is a MODAL rather than a route
    # or an on-page script, so it tracks that modal's registration in every
    # environment. The show-everything-locally policy below is safe only for
    # rails whose destination exists regardless of the flag; applying it to
    # Coinbase is what put a dead button in front of design review and made the
    # entire test suite render one.
    return cdp_ramp_modal_available? if rail.to_sym == :coinbase

    return true unless Rails.env.production?

    case rail.to_sym
    when :coinflow       then AppFlags.coinflow?
    when :aeropay        then AppFlags.aeropay?
    when :paypal, :venmo then Payments.paypal_checkout?
    when :stripe         then Payments.stripe?
    else false
    end
  end
end
