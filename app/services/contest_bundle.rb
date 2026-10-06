# Curated contest + landing-page bundles the operator can one-click provision
# from the contest generator page (ContestsController#generate_bundle).
#
# Two provisioning paths:
#
#   1. generate! — server-funded via Contest's after_create callback (needs
#      SOLANA_ADMIN_KEY). Used locally and from Rails console.
#
#   2. build_unpersisted_contest + finalize_phantom! — Phantom-driven, mirrors
#      ContestsController#create / #finalize. The operator's Phantom signs the
#      create_contest TX (funds the prize pool from their USDC), and the DB
#      row + landing page are only created after the on-chain TX confirms.
#      This is the only path that works on prod (SOLANA_ADMIN_KEY is
#      intentionally absent there per OPSEC-010).
#
# Both paths are idempotent (find_or_create) — re-running is safe.
module ContestBundle
  ALL = {
    "alpha" => {
      label: "Turf Totals Alpha",
      contest: {
        name: "Turf Totals Alpha Contest",
        slug: "turf-totals-alpha-contest",
        game_type: "turf_totals",
        contest_type: "medium",
        slate_name: "World Cup 2026 Group 1"
      },
      landing_page: {
        slug: "alpha",
        name: "Turf Totals Alpha Contest",
        headline: "FIFA World Cup Fantasy Contest",
        subheadline: "Draft Six Teams from the Opening Slate of FIFA World Cup Group Play. Climb the Leaderboard as your teams score points.",
        badge: "Alpha Test",
        cta_label: "Enter the Alpha Contest",
        background_style: "blobs"
      }
    },
    "world_cup" => {
      label: "World Cup $1,000",
      contest: {
        name: "World Cup $1000 Turf Total Contest",
        slug: "world-cup-1000-turf-total-contest",
        game_type: "turf_totals",
        contest_type: "large",
        slate_name: "World Cup 2026 Group 1"
      },
      landing_page: {
        slug: "world-cup",
        name: "World Cup $1000 Contest",
        headline: "Win $1,000 at the World Cup",
        subheadline: "Draft six teams from the opening slate of FIFA World Cup group play. Top score takes the $1,000 grand prize.",
        badge: nil,
        cta_label: "Enter the $1,000 Contest",
        background_style: "circles"
      }
    }
  }.freeze

  def self.spec_for(key)
    ALL[key] || raise(ArgumentError, "Unknown bundle: #{key.inspect}")
  end

  # Idempotently provision a bundle: its contest (+ on-chain PDA via the
  # server-funded after_create callback) and its landing page. Returns
  # { contest:, landing_page: }. Requires SOLANA_ADMIN_KEY — works locally,
  # not in prod.
  def self.generate!(key, creator: nil)
    spec = spec_for(key)
    contest = find_or_create_contest(spec[:contest], creator)
    landing = find_or_create_landing_page(spec[:landing_page], contest)
    { contest: contest, landing_page: landing }
  end

  # Build an UNSAVED Contest with the bundle's attrs filled in. Used by
  # ContestsController#generate_bundle to build the partially-signed
  # create_contest TX for the operator's Phantom to sign.
  def self.build_unpersisted_contest(key, creator)
    apply_contest_attrs(Contest.new, spec_for(key)[:contest], creator)
  end

  # Phantom-flow finalize: after the operator's Phantom has signed and
  # broadcast the create_contest TX, persist the Contest (skipping the
  # server-funded on-chain callback — the on-chain PDA already exists) and
  # its LandingPage. Idempotent.
  def self.finalize_phantom!(key, creator, contest_pda, tx_signature, season_id: nil)
    spec = spec_for(key)
    contest = Contest.find_or_create_by!(slug: spec[:contest][:slug]) do |c|
      apply_contest_attrs(c, spec[:contest], creator)
      c.season_id             = season_id if season_id.present?
      c.onchain_contest_id    = contest_pda
      c.onchain_tx_signature  = tx_signature
      # generate_bundle built the TX from onchain_params — the USDT fee
      # (entry_fee_by_currency slot 1) is funded on-chain.
      c.accepts_usdt          = true
      c.skip_onchain_callback = true
    end
    landing = find_or_create_landing_page(spec[:landing_page], contest)
    { contest: contest, landing_page: landing }
  end

  def self.find_or_create_contest(spec, creator)
    Contest.find_or_create_by!(slug: spec[:slug]) do |c|
      apply_contest_attrs(c, spec, creator)
    end
  end

  def self.apply_contest_attrs(contest, spec, creator)
    slate  = resolve_slate(spec[:slate_name])
    format = Contest::FORMATS[spec[:contest_type]] || {}
    contest.name            = spec[:name]
    # Slug is set explicitly now that Contest no longer auto-derives it from name
    # (name/slug epic Part A). Fall back to a parameterized name for forward-compat
    # if a future spec omits it.
    contest.slug            = spec[:slug] || spec[:name].to_s.parameterize
    contest.game_type       = spec[:game_type]
    contest.contest_type    = spec[:contest_type]
    contest.slate           = slate
    contest.status          = "open"
    contest.entry_fee_cents = format[:entry_fee_cents]
    contest.max_entries     = format[:max_entries]
    contest.starts_at       = slate&.starts_at
    contest.user            = creator
    contest.season_id      ||= SeasonConfig.current_season_id
    contest
  end

  def self.find_or_create_landing_page(spec, contest)
    LandingPage.find_or_create_by!(slug: spec[:slug]) do |l|
      l.name             = spec[:name]
      l.headline         = spec[:headline]
      l.subheadline      = spec[:subheadline]
      l.badge            = spec[:badge]
      l.cta_label        = spec[:cta_label]
      l.background_style = spec[:background_style]
      l.contest          = contest
      l.active           = true
    end
  end

  def self.resolve_slate(slate_name)
    return nil if slate_name.blank?

    Slate.find_by(name: slate_name) ||
      raise("Slate #{slate_name.inspect} not found — run db:seed first")
  end
end
