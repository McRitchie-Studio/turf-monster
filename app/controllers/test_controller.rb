# Test-only endpoints used by Playwright specs. Routes are guarded in
# config/routes.rb with `unless Rails.env.production?` so this controller is
# reachable in dev (Playwright's default boot) but unreachable in production.
class TestController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :verify_authenticity_token

  # Fast inter-spec reset. Playwright spec files call this in test.beforeAll
  # to drop the most common cross-spec pollution sources without re-running
  # the full e2e/seed.rb. Specifically:
  #
  #   - rack-attack throttle counters: a previous spec's repeated logins
  #     push `login/email` over its 5/min limit; the next spec's
  #     loginAdmin then hangs at form-submit and times out.
  #   - Entry-token Rails.cache (entry_tokens/v1/...): a stale post-mint
  #     cache lingers ~60s and the next spec reads "0 available" even
  #     after the chain shows a token.
  #   - OmniAuth.config.mock_auth: stale provider hashes from
  #     set_oauth_mock leak into the next spec and sign in the wrong user.
  #
  # Returns counts so flake hunts can grep the spec output.
  def reseed
    cleared = []

    # Rails.cache.delete_matched under the Redis cache store returns the
    # underlying Redis client array (circular ref) — don't render its return
    # value or to_json recurses to SystemStackError. We discard the return
    # and just note that we ran the call.
    #
    # rack-attack writes throttle counters under `rack::attack:<epoch>:<name>:<discriminator>`
    # (DOUBLE colon) — NOT `rack-attack:*`. Get the pattern wrong and the
    # counters survive the reseed and the next spec's login times out.
    begin
      Rails.cache.delete_matched("rack::attack:*")
      cleared << "rack::attack"
    rescue => e
      Rails.logger.warn "[reseed] delete_matched rack::attack:* failed: #{e.message}"
    end

    begin
      Rails.cache.delete_matched("entry_tokens/v1/*")
      cleared << "entry_tokens"
    rescue => e
      Rails.logger.warn "[reseed] delete_matched entry_tokens/v1/* failed: #{e.message}"
    end

    if defined?(OmniAuth) && OmniAuth.config.respond_to?(:mock_auth)
      OmniAuth.config.mock_auth.clear
      # Restore the real Google redirect for interactive dev between runs;
      # set_oauth_mock re-enables test_mode right before it's needed.
      OmniAuth.config.test_mode = false
      cleared << "omniauth_mocks"
    end

    # Wipe non-core users (id > 5) that linger from prior signup-flow tests.
    # Without this, referrals.spec.js's second run finds the existing
    # Phantom/Google/email-signup user with invited_by_id already set;
    # set_inviter doesn't re-fire; inviter counters stay at 0; assertions
    # fail. Core users (alex/mcritchie/mason/mack/turf at IDs 1-5 — human is
    # `alex`, bot is `mcritchie` after the 2026-09-04 swap, which reversed the
    # 2026-06-02 flip) stay — specs depend on their slugs being stable.
    #
    # destroy_all (not delete_all) so dependent: :destroy on User cascades
    # to entries, transaction_logs, stripe_purchases.
    begin
      victims = User.where("id > ?", 5)
      count = victims.count
      if count > 0
        victims.destroy_all
        cleared << "non_core_users(#{count})"
      end
    rescue => e
      Rails.logger.warn "[reseed] non-core user cleanup failed: #{e.class}: #{e.message[0,160]}"
    end

    # Wipe core users' entries too — survivor.spec.js's "logged-in user
    # can enter and make a round-1 pick" logs in as mason (core, id=3)
    # and POSTs /contests/world-cup-survivor/enter. A prior run's entry
    # rejects the new POST as a duplicate. Same shape as the non-core
    # cleanup but for entries the user-cascade can't reach.
    # FK order: survivor_picks → entries → selections.
    begin
      survivor_pick_count = SurvivorPick.delete_all
      selection_count     = Selection.delete_all
      entry_count         = Entry.delete_all
      cleared << "core_entries(#{entry_count})" if entry_count > 0
    rescue => e
      Rails.logger.warn "[reseed] entry cleanup failed: #{e.class}: #{e.message[0,160]}"
    end

    # Reset the geo row to its seeded default (geo-blocking OFF, the configured
    # default blocklist). `enabled` is a DB column (NOT session-scoped),
    # so a prior spec that flips geo-blocking on — geo.spec.js "blocked state",
    # geo_hold_validation.spec.js, or a retry that fails before its cleanup —
    # leaves blocking ENABLED for every later spec. With blocking on, the
    # admin/geo "Simulate WA" → "Simulating WA" flow renders/redirects
    # differently and times out (the documented geo.spec.js full-suite flake).
    # Specs that need blocking re-enable it themselves after reseed.
    begin
      geo = Studio::GeoSetting.current
      geo.enabled = false
      geo.banned_subdivisions = Studio.geo_default_banned_subdivisions
      geo.save!
      cleared << "geo_setting"
    rescue => e
      Rails.logger.warn "[reseed] geo_setting reset failed: #{e.class}: #{e.message[0,160]}"
    end

    render json: { ok: true, cleared: cleared }
  end

  # Phantom-mock admin handoff. The Playwright Phantom mock signs with
  # MOCK_PUBKEY_B58 (e2e/phantom-mock.js: 6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt);
  # the canonical alex user's wallet is the operator's real Phantom
  # (7ZDJp7FU…) so manual browser auth resolves to alex. To keep both
  # flows working from the same dev DB:
  #
  #   - `use_phantom_mock_admin` — called from Playwright globalSetup.
  #     Stashes the human operator's current wallet into a Rails.cache key,
  #     then points them at MOCK_PUBKEY so loginViaPhantom resolves to the
  #     human admin. It resolves the human by EMAIL — see HUMAN_ADMIN_EMAIL for
  #     why that is not the username.
  #   - `restore_canonical_admin` — called from Playwright globalTeardown.
  #     Reads the stashed wallet back. If the cache key is missing
  #     (crash, container restart, expired), falls back to
  #     ENV["ADMIN_CANONICAL_WALLET"] or the hard-coded operator wallet.
  PHANTOM_MOCK_WALLET      = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze
  ADMIN_WALLET_STASH_KEY   = "test/canonical_admin_wallet".freeze
  CANONICAL_ADMIN_FALLBACK = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze

  # THE HUMAN OPERATOR, KEYED BY EMAIL — because the username churns and the
  # email does not. It has moved twice: `alex` -> `mcritchie` (2026-06-02) ->
  # `alex` (2026-09-04, traded back with the shared team account).
  #
  # A stale username here does NOT fail as a missing user, which is what makes it
  # worth keying off: it finds the OTHER seeded admin, tries to hand it the mock
  # wallet the human already holds, and dies `Web3 solana address has already been
  # taken` (422) inside Playwright's globalSetup — so EVERY shard fails before
  # running a single test, reading as a wallet bug rather than a rename. Measured
  # 2026-09-04.
  HUMAN_ADMIN_EMAIL = "alex@mcritchie.studio".freeze

  def use_phantom_mock_admin
    human = User.find_by!(email: HUMAN_ADMIN_EMAIL)
    Rails.cache.write(ADMIN_WALLET_STASH_KEY, human.web3_solana_address, expires_in: 1.hour)
    human.update!(web3_solana_address: PHANTOM_MOCK_WALLET)
    render json: { ok: true, from: Rails.cache.read(ADMIN_WALLET_STASH_KEY), to: PHANTOM_MOCK_WALLET }
  end

  def restore_canonical_admin
    human = User.find_by!(email: HUMAN_ADMIN_EMAIL)
    stashed = Rails.cache.read(ADMIN_WALLET_STASH_KEY)
    Rails.cache.delete(ADMIN_WALLET_STASH_KEY)
    canonical = stashed.presence ||
      ENV["ADMIN_CANONICAL_WALLET"].presence ||
      CANONICAL_ADMIN_FALLBACK
    human.update!(web3_solana_address: canonical)
    render json: { ok: true, to: canonical, source: (stashed ? "stash" : "fallback") }
  end

  # Set the OmniAuth mock_auth payload for the next /auth/:provider call.
  # Playwright posts to this immediately before navigating to /auth/google_oauth2
  # so the e2e spec controls who "signs in" with Google.
  def set_oauth_mock
    provider = params[:provider].presence || "google_oauth2"
    # Opt into test_mode on demand so /auth/:provider short-circuits to the
    # callback with this mock instead of redirecting to Google. Development
    # keeps test_mode OFF by default (real Google flow); this turns it on for
    # the duration of a Playwright run, and reseed flips it back off.
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[provider.to_sym] = OmniAuth::AuthHash.new(
      provider: provider,
      uid:      params[:uid].to_s,
      info: {
        email: params[:email].to_s,
        name:  params[:name].to_s
      }
    )
    render json: { ok: true }
  end

  # Force a user's referral cache counters to a specific value so the
  # Playwright account-UI tests can exercise the "1 of 2 friends" and
  # "ENTRY TOKEN COMING SOON" states without staging full signup flows.
  def set_user_referral_counts
    user = User.find_by!(slug: params[:slug])
    user.update_columns(
      invitees_count:            params[:invitees_count].to_i,
      invitees_in_contest_count: params[:invitees_in_contest_count].to_i
    )
    render json: { ok: true, user: user.slug,
                   ic:  user.invitees_count,
                   iic: user.invitees_in_contest_count }
  end

  # Create an :active Entry for the current session's user in a given
  # contest. Triggers Entry#after_commit → ReferralProgress.mark_entered!
  # naturally — same callback path the real /enter action would hit, but
  # without the on-chain Vault dance that needs devnet connectivity.
  # Returns the user's + inviter's slugs so the spec can verify state.
  def create_active_entry
    return render json: { error: "not logged in" }, status: :unauthorized unless current_user

    contest = Contest.find_by!(slug: params[:contest_slug])
    Entry.create!(user: current_user, contest: contest, status: :active)

    render json: {
      ok: true,
      user_slug:    current_user.slug,
      inviter_slug: current_user.inviter&.slug
    }
  end

  # ── /contests featured-rail fixtures ──────────────────────────────────
  #
  # The rail's two browser-only properties — the right-edge fade appearing only
  # while something is off-screen, and the open-before-coming-soon order — both
  # need MORE THAN ONE contest to be observable, and the dev seed ships exactly
  # one. So the spec states its own premise here rather than inheriting a
  # fixture it cannot see.
  #
  # Every row is slugged with one prefix and the spec deletes them by that
  # prefix when it finishes, so this cannot leave the rail wider than it found
  # it. That matters more than it sounds: the lane runs `workers: 1` against
  # ONE database, and a leftover contest is paid for by every later spec that
  # measures this page.
  #
  # `skip_onchain_callback` is not optional. Contest's after_create mints a
  # Contest PDA on devnet unless the flag is set, and Rails.env.test? — which
  # skips it automatically — is FALSE here: Playwright boots the app in
  # DEVELOPMENT. Without the flag each of these would make a real RPC round
  # trip and the seeding call would hang or fail.
  E2E_RAIL_SLUG_PREFIX = "e2e-rail-".freeze

  def seed_contests
    count = params[:count].to_i.clamp(1, 12)
    slate = Slate.order(:id).first
    return render json: { error: "no slate to hang a contest on" }, status: :unprocessable_entity if slate.nil?

    made = (1..count).map do |i|
      Contest.new(
        # ONE deliberately long name in the set. The rail's cards are a fixed
        # width and their titles are pinned to a single line; a fixture of
        # uniformly short names makes that measurement pass whether the rule is
        # applied or not.
        name: i == 1 ? "E2E Rail Contest With A Deliberately Very Long Operator Typed Name" : "E2E Rail Contest #{i}",
        slug: "#{E2E_RAIL_SLUG_PREFIX}#{i}",
        status: "open",
        coming_soon: false,
        entry_fee_cents: 1900,
        max_entries: 29,
        contest_type: "standard",
        slate: slate,
        # Newest first inside the rail's open band, so the spec can name the
        # order it expects rather than discover it.
        created_at: i.minutes.ago
      ).tap { |c| c.skip_onchain_callback = true }.tap(&:save!)
    end

    render json: { ok: true, slugs: made.map(&:slug) }
  end

  def clear_seeded_contests
    removed = Contest.where("slug LIKE ?", "#{E2E_RAIL_SLUG_PREFIX}%").destroy_all.map(&:slug)
    render json: { ok: true, removed: removed }
  end

  # Give the signed-in user a managed (custodial) wallet — i.e. make them a
  # GRANDFATHERED web2 user.
  #
  # Why this exists: web3-only onboarding (AppFlags.web3_only_onboarding?) means
  # signup no longer mints a managed wallet, so a spec whose SUBJECT is the
  # managed-wallet path (quest_ladder_web2) can no longer get one as a side
  # effect of signing up. That audience still exists and is still supported —
  # so the spec now STATES its premise here instead of inheriting it.
  #
  # Mints its own keypair rather than calling User#generate_managed_wallet!,
  # which deliberately early-returns while the flag is on.
  def grant_managed_wallet
    return render json: { error: "not logged in" }, status: :unauthorized unless current_user

    if current_user.web2_solana_address.blank?
      keypair = Solana::Keypair.generate
      current_user.update!(web2_solana_address: keypair.to_base58,
                           encrypted_web2_solana_private_key: keypair.encrypt)
    end

    render json: { ok: true, slug: current_user.slug,
                   address: current_user.web2_solana_address,
                   wallet_kind: current_user.wallet_kind }
  end

  # Stage a user's quest ladder position so Playwright can land on a specific
  # quest_step / next_quest without driving the (on-chain) username + chat
  # quests first. The contest-card ladder + the gear "Next: …" pointer both read
  # User#quest_step / #next_quest, which derive from these timestamp columns:
  #   username_changed_at  → first_username_change?  (username quest done)
  #   first_chat_message_at → first_chat_message?    (chat quest done)
  #   joined_email_list_at  → subscribed_to_newsletter? (newsletter quest done)
  # Mirrors set_user_referral_counts: update_columns (no callbacks/validations),
  # current_user by default (slug optional). Only advances flags FORWARD — fresh
  # users already start with all three nil.
  def set_quest_state
    user = params[:slug].present? ? User.find_by(slug: params[:slug]) : current_user
    return render json: { error: "no user" }, status: :unprocessable_entity unless user

    truthy = ->(v) { v == true || v.to_s == "true" }
    cols = {}
    cols[:username_changed_at]    = Time.current if truthy.call(params[:username_changed])
    cols[:first_chat_message_at]  = Time.current if truthy.call(params[:chat_sent])
    if truthy.call(params[:subscribed])
      cols[:joined_email_list_at] = Time.current
      cols[:left_email_list_at]   = nil
    end
    user.update_columns(cols) if cols.any?

    render json: { ok: true, slug: user.slug,
                   quest_step: user.quest_step, next_quest: user.next_quest }
  end

  # Stage a WEB3 account for the step-up specs: an email-addressable user that
  # holds a self-custody wallet and a remembered brand.
  #
  # There is no way to reach this state through the UI in a headless browser —
  # a real self-custody link needs an extension to sign — and it is the exact
  # precondition the step-up card exists for (a wallet account arriving by magic
  # link). So the backdoor stages the ACCOUNT, and the spec still walks the real
  # magic-link round trip into it, which is where the behaviour under test lives.
  #
  # web3_solana_address is a synthetic base58 keypair, not a real wallet: the
  # specs assert the CARD, never a signature, so the address only has to be
  # well-formed and unique.
  #
  # SECURITY: this MINTS a verified, wallet-holding account for ANY email and
  # overwrites the wallet on an existing one — the same account-takeover shape
  # as magic_link_token below, so it carries the same hard-gate. The routes.rb
  # guard only blocks production; never let a staging / review-app dyno
  # (RAILS_ENV != production) serve it.
  def grant_web3_wallet
    return head :forbidden unless Rails.env.test? || Rails.env.development?

    email = params[:email].to_s.strip.downcase
    return render json: { error: "email required" }, status: :unprocessable_entity if email.blank?

    user = User.find_or_initialize_by(email: email)
    user.name ||= "Wallet Tester"
    user.save! if user.new_record?

    user.update_columns(
      web3_solana_address: Solana::Keypair.generate.to_base58,
      # Straight through the normalizer so a spec cannot stage a brand the app
      # itself would refuse to store.
      web3_wallet_provider: Solana::WalletProvider.normalize(params[:provider]),
      web3_authenticated_at: Time.current,
      email_verified_at: Time.current
    )

    render json: { ok: true, slug: user.slug, address: user.web3_solana_address,
                   provider: user.web3_wallet_provider, wallet_kind: user.wallet_kind }
  end

  # Mint a magic-link token for an email so Playwright can drive the
  # create-or-login consume flow without a real inbox. Mirrors what
  # MagicLinksController#create emails (contest + validated picks fold into the
  # signed return_to).
  #
  # SECURITY: this hands out a LIVE, consumable sign-in credential for ANY
  # email — an account-takeover primitive if exposed. The route guard only
  # blocks production, so we additionally hard-gate to test/development here:
  # never let a staging / review-app dyno (RAILS_ENV != production) serve it.
  def magic_link_token
    return head :forbidden unless Rails.env.test? || Rails.env.development?

    contest = Contest.find_by(slug: params[:contest].presence)
    return_to = contest ? contest_path(contest) : nil
    if contest && params[:picks].present?
      ids   = params[:picks].to_s.split(",").map(&:to_i).select(&:positive?).first(6)
      picks = ids & contest.matchups.where(id: ids).pluck(:id)
      return_to = "#{return_to}?picks=#{picks.join(',')}" if picks.present?
    end
    # age_attested: the e2e login backdoor models a user who checked the
    # legal-age box on the auth card (consume refuses NEW accounts without it).
    token = Studio::Link.create_magic_link(email: params[:email].to_s, return_to: return_to, age_attested: true).token
    render json: { ok: true, token: token, url: link_path(token: token) }
  end

  # Read-only JSON view of a user's referral state so specs can assert
  # without scraping HTML. Looks up by slug (path param).
  def user_info
    user = User.find_by!(slug: params[:slug])
    render json: {
      slug:                      user.slug,
      username:                  user.username,
      email:                     user.email,
      contest_entered:           user.contest_entered?,
      invitees_count:            user.invitees_count,
      invitees_in_contest_count: user.invitees_in_contest_count,
      inviter_slug:              user.inviter&.slug
    }
  end
end
