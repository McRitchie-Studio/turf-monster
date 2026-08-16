ENV["RAILS_ENV"] ||= "test"

# I1 (Stage 3 audit): SimpleCov must start before Rails loads any app code
# so it can track which lines get hit. Opt-in via COVERAGE=1 to keep the
# default `bin/rails test` fast; ENFORCE_COVERAGE=1 turns the line threshold
# into a hard gate. Parallel workers each get a UNIQUE command_name + persist
# their result via the parallelize_setup/teardown hooks below, so the aggregate
# is real — it used to collapse to a single "Worker 0" (~2%) because every
# forked worker wrote the resultset under the same name and overwrote the rest.
if ENV["COVERAGE"] == "1" || ENV["CI"]
  require "simplecov"
  SimpleCov.start "rails" do
    merge_timeout 3600
    enable_coverage :branch
    add_group "Models",      "app/models"
    add_group "Controllers", "app/controllers"
    add_group "Webhooks",    "app/controllers/webhooks"
    add_group "Jobs",        "app/jobs"
    add_group "Services",    "app/services"
    add_filter "/test/"
    add_filter "/config/"
    add_filter "/db/"
    add_filter "/vendor/"
    # Floor set just below the real merged aggregate (~50% line / ~55% branch,
    # stable across local + eager-load/CI). Was a dormant guess of 70 from when
    # the broken merge made coverage look like ~2%. Ratchet upward as coverage
    # grows; ENFORCE_COVERAGE=1 is opt-in (not wired into CI yet).
    minimum_coverage(line: 48) if ENV["ENFORCE_COVERAGE"] == "1"
  end
end

require_relative "../config/environment"
require "rails/test_help"
# Object#stub (used across controller/model tests) ships in minitest/mock but is
# only pulled in transitively by some files' load order — so a single-file or
# unlucky-ordered parallel run could hit "undefined method `stub`". Require it
# explicitly so stubbing is deterministically available everywhere.
require "minitest/mock"

# Shared test doubles. test/support/* is auto-loaded so individual test
# files don't need to require_relative them.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    # SimpleCov + Rails parallel testing: each test runs in a forked worker, and
    # unless each worker writes its resultset under a UNIQUE command_name they
    # overwrite each other — collapsing the report to one worker's coverage
    # (~2%). (ENV["TEST_ENV_NUMBER"] is a parallel_tests-gem var, nil under
    # Rails' built-in parallelize — which is why the old static name was always
    # "Worker 0".) Name each worker by its index and persist its result on
    # teardown; SimpleCov merges all the per-worker resultsets in the primary
    # process at_exit. Registered only under COVERAGE/CI; a no-op when workers
    # falls back to 1 (the hooks just don't fire).
    if ENV["COVERAGE"] == "1" || ENV["CI"]
      parallelize_setup    { |worker| SimpleCov.command_name "Worker #{worker}" }
      parallelize_teardown { |_worker| SimpleCov.result }
    end

    fixtures :all

    # Give `user` a managed (custodial) wallet, whatever the onboarding flag says.
    #
    # Signup stopped minting one when web3-only onboarding became the DEFAULT
    # (2026-08-15 — AppFlags.web3_only_onboarding?), and a large family of suites
    # used to inherit their custodial wallet from that mint: wallet export,
    # withdraw, cash-out, off-ramp, self-custody. None of them are about
    # onboarding. They are about the rails that still serve every managed wallet
    # ALREADY out there, and those users need to exist to be tested.
    #
    # The flag gates minting AT SIGNUP, so this turns it off for exactly the
    # length of the mint and restores whatever was there — including "not set".
    # Prefer this over stamping web2_solana_address by hand: generate_managed_wallet!
    # also writes the encrypted key, without which solana_keypair returns nil and
    # the signing half of those suites is silently untested.
    def grant_managed_wallet!(user)
      original = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
      ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
      user.generate_managed_wallet!
      user.reload
    ensure
      if original.nil?
        ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
      else
        ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = original
      end
    end
  end
end

class ActionDispatch::IntegrationTest
  # OmniAuth.config is a PROCESS-GLOBAL singleton shared by every test in a
  # parallel worker. TestController#reseed (hit by TestControllerTest's
  # `post /test/reseed`, and by Playwright at runtime) flips
  # `test_mode = false` + clears mock_auth to model the real-Google dev flow
  # (commit 85a6870). Without a per-test reset, whichever OmniAuth callback
  # test the worker happens to run *after* that reseed lands on the real
  # OAuth2 strategy and fails with `csrf_detected` — the state check the mock
  # path skips. Re-assert the test baseline before every integration test so
  # worker sharding / ordering can't make OmniAuth flaky. Per-class setups run
  # after this (parent callbacks fire first), so they still layer their own
  # mock_auth on top of the cleared hash.
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth.clear
    # ENABLE_AGE_GATE leaks from the operator's .env into the test env via
    # dotenv-rails, so a developer dogfooding the gate (flag on locally) would
    # see entry tests 422 with age_required while CI (clean env) stays green.
    # Force the gate OFF as the per-test baseline — matching CI — so the suite
    # is hermetic against ambient .env. The age-gate tests opt back IN
    # explicitly via with_age_gate (test/controllers/contests_age_gate_test.rb).
    ENV.delete("ENABLE_AGE_GATE")
  end

  # Follow the redirect chain all the way to the page that actually RENDERS.
  #
  # A magic-link consume lands on the ROOT since 2026-08-15, and root is
  # contests#world_cup — a redirector to the live board. So the render an auth
  # test wants to assert on is two hops away, not one, and it would move again
  # the day root's target changes. Following to the first non-redirect keeps
  # these assertions about the LANDING PAGE instead of about the hop count.
  #
  # Safe for the one-shot session payloads these tests read (the onboarding
  # chain, the wallet-setup prompt): a redirect renders nothing, so no
  # intermediate hop can consume them on the way through.
  def follow_redirects!(limit: 5)
    limit.times do
      break unless response.redirect?

      follow_redirect!
    end
    assert_not response.redirect?, "still redirecting after #{limit} hops — is there a loop?"
    response
  end

  # Passwordless: email auth is magic-link only. Logging in = mint a magic-link
  # token the same way MagicLinksController#create does, then drive the consume
  # to establish the session (existing email user → sign_in_existing).
  # Signature kept as log_in_as(user) so the many call sites are unchanged.
  #
  # The emailed link's GET is now a scanner-safe "Confirm sign-in" interstitial
  # that does NOT consume the token; the human's button press POSTs to
  # /magic_link/:token, and THAT burns the token + signs in. So log_in_as POSTs
  # to consume directly (a prior GET to the interstitial would be a no-op).
  #
  # MagicLinksController#sign_in_existing stamps email_verified_at when blank
  # (clicking the link IS proof of ownership). That's correct product behavior
  # but a test that deliberately set email_verified_at: nil shouldn't have the
  # mere act of authenticating silently flip it — so we preserve whatever
  # verification state the test arranged before the consume.
  def log_in_as(user)
    raise ArgumentError, "log_in_as requires a user with an email (use log_in_as_onchain for wallet users)" if user.email.blank?
    verified_before = user.email_verified_at
    token = Studio::Link.create_magic_link(email: user.email).token
    post magic_link_consume_path(token: token)
    user.update_column(:email_verified_at, verified_before) if user.reload.email_verified_at != verified_before
  end

  # Mint a magic-link token string. Studio::Link replaced the app-local MagicLink
  # model whose .generate returned a token directly; this keeps tests terse.
  def magic_token(**attrs)
    Studio::Link.create_magic_link(**attrs).token
  end

  # The magic-link Studio::Link for an email (email now rides in metadata, not a
  # column, so find_by(email:) no longer works).
  def magic_link_for(email)
    Studio::Link.magic_links.detect { |link| link.email == email.to_s.strip.downcase }
  end

  # Log in via Solana wallet auth — sets session[:onchain] = true
  # Returns the Ed25519 signing key for use in subsequent signature proofs
  def log_in_as_onchain(user)
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update!(web3_solana_address: pubkey_b58)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    post "/auth/solana/verify", params: { message: message, signature: sig_b58, pubkey: pubkey_b58 }, as: :json
    assert_response :success, "Onchain login failed: #{response.body}"

    key
  end

  # Sign a contest entry message with the given key, returning params hash for POST /enter
  def sign_entry_message(key, user, contest_name)
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    # OPSEC-005: signed message must embed `User-ID: <id>` so the server
    # binds the signature to the active session's user.
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nUser-ID: #{user.id}\n\nEnter contest: #{contest_name}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    { message: message, signature: sig_b58, pubkey: pubkey_b58 }
  end
end
