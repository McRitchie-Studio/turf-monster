# View seam for the wallet-setup modal's "how do I install this?" CTA.
module WalletSetupHelper
  # Phantom's own guide — the fallback target, and a real one: it covers the
  # same install → create-a-wallet path as the house guide.
  PHANTOM_GUIDE_URL = "https://phantom.com/learn/guides/how-to-create-a-new-wallet".freeze

  # The house guide at /getting-started is the intended destination (operator
  # call, 2026-08-11) but it ships in a SEPARATE task —
  # /tasks/phantom-onboarding-guide-page, which owns the route and the page.
  #
  # So resolve it at render time instead of hard-linking a route this branch
  # does not define: if that task has landed, route helpers answer to
  # getting_started_path and users get the house guide; if it has not, they get
  # Phantom's guide rather than a 404. The check is on the ROUTE, not on a flag
  # or a date, so the CTA switches over the moment the page exists — and no
  # ordering mistake between the two tasks can ever ship a dead link.
  def wallet_setup_guide_url
    return getting_started_path if respond_to?(:getting_started_path)

    PHANTOM_GUIDE_URL
  end

  # True when the resolved guide is off-site (the fallback above), so the link
  # can open in a new tab and keep the user's lineup alive in this one.
  def wallet_setup_guide_external?
    wallet_setup_guide_url.start_with?("http")
  end
end
