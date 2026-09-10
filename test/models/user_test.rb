require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "display_name returns username when present" do
    user = users(:alex)
    assert_equal "mcritchie_test", user.display_name
  end

  test "display_name falls back to capitalized email prefix when username and name are blank" do
    user = User.create!(email: "newplayer@mcritchie.studio")
    user.update_column(:username, nil) # usernames auto-generate; clear it to exercise the fallback
    assert_equal "Newplayer", user.display_name
  end

  test "every new account is auto-assigned a username" do
    user = User.create!(email: "auto@mcritchie.studio")
    assert user.username.present?, "signup should auto-generate a username"
    assert_match(/\A[a-zA-Z0-9_-]+\z/, user.username)
  end

  test "an explicitly provided username is kept" do
    user = User.create!(email: "explicit@mcritchie.studio", username: "chosen-name")
    assert_equal "chosen-name", user.username
  end

  # --- Slug finalization ------------------------------------------------------
  #
  # Sluggable's before_save runs BEFORE the insert, so the id is nil and the slug
  # lands as "<base>-". It used to gain the id only because
  # generate_managed_wallet! saved the row a second time — an accident that
  # web3-only onboarding removes. These pin the slug to the id regardless.

  test "a new account's slug carries its id" do
    user = User.create!(email: "slug-basic@mcritchie.studio", username: "slugbasic")
    assert_equal "slugbasic-#{user.id}", user.reload.slug
  end

  test "the slug carries its id even with no managed wallet minted" do
    with_web3_only("true") do
      user = User.create!(email: "slug-web3@mcritchie.studio", username: "slugweb3")
      assert_nil user.web2_solana_address, "precondition: no wallet was minted"
      assert_equal "slugweb3-#{user.id}", user.reload.slug,
                   "the slug must not depend on the managed-wallet callback saving the row"
    end
  end

  test "an admin's slug carries its id too" do
    # Admins never get a managed wallet (OPSEC-044), so before this fix they kept
    # the dangling shape — the seeded `alex-` / `turf-` slugs are exactly that.
    user = User.create!(email: "slug-admin@mcritchie.studio", username: "slugadmin", role: "admin")
    assert_equal "slugadmin-#{user.id}", user.reload.slug
  end

  test "two accounts with the same display name get distinct slugs" do
    # The id is what makes the slug unique, and users.slug carries a UNIQUE
    # index — a dangling "<base>-" for two same-named users is a collision
    # waiting to happen.
    a = User.create!(email: "dup-a@mcritchie.studio", name: "Same Name", username: "dupa")
    b = User.create!(email: "dup-b@mcritchie.studio", name: "Same Name", username: "dupb")
    assert_not_equal a.reload.slug, b.reload.slug
    assert_match(/-#{a.id}\z/, a.slug)
    assert_match(/-#{b.id}\z/, b.slug)
  end

  # --- Web3-only onboarding (AppFlags.web3_only_onboarding?) ------------------

  test "signup mints a managed wallet while web3-only onboarding is off" do
    # The pre-existing behaviour, asserted so the flag's OFF path stays honest.
    # "Off" is an explicit "false" since the flag became a kill-switch on
    # 2026-08-15 — an absent var is now the ON side, and passing nil here would
    # test the opposite of what this test's name claims.
    with_web3_only("false") do
      user = User.create!(email: "web2wallet@mcritchie.studio")
      assert user.web2_solana_address.present?, "flag off should still mint a custodial wallet"
      assert_equal :managed, user.wallet_kind
    end
  end

  test "signup mints NO managed wallet while web3-only onboarding is on" do
    with_web3_only("true") do
      user = User.create!(email: "web3only@mcritchie.studio")
      assert_nil user.web2_solana_address, "web3-only onboarding must not mint a custodial wallet"
      assert_nil user.encrypted_web2_solana_private_key, "no custodial key should be stored either"
      assert_equal :none, user.wallet_kind
      # The account itself is fully valid and signed-in-able — the wallet is the
      # only thing missing (has_authentication_method is satisfied by the email).
      assert user.persisted?
      assert user.username.present?
    end
  end

  test "an existing managed wallet is untouched when the flag is on" do
    # The flag gates MINTING at signup, never the wallets already out there.
    with_web3_only("true") do
      user = users(:jordan)
      user.update_columns(web2_solana_address: "PreexistingManaged1")
      user.generate_managed_wallet!
      assert_equal "PreexistingManaged1", user.reload.web2_solana_address
    end
  end

  # Deliberately NOT under `private` — Minitest collects tests from public
  # instance methods, and a stray visibility change here would silently stop
  # every `test` block defined after it in this file from running.
  def with_web3_only(value)
    original = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
    value.nil? ? ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING") : ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING") : ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = original
  end

  test "new wallet account claims parked username before generating a random one" do
    wallet = User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:wallet)

    user = User.create!(web3_solana_address: wallet)

    # Derived, like the name below it. The usernames `alex` and `mcritchie`
    # traded owners on 2026-09-04, and this test is about the CLAIM firing, not
    # about which name the roster currently parks. The roster's content is
    # pinned once, in SeedIdentitiesTest.
    assert_equal User.parked_username_for(email: "alex@mcritchie.studio"), user.username
    assert_equal "admin", user.role
    # Derived from the identity list, not spelled out: the claim is what this
    # test is about, and pinning the literal name made a seed-copy change fail
    # here as though the claim had broken.
    assert_equal User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:name), user.name
  end

  test "new email account claims parked username before generating a random one" do
    user = User.create!(email: "team@mcritchie.studio")

    assert_equal User.parked_username_for(email: "team@mcritchie.studio"), user.username
    assert_equal "admin", user.role
    assert_equal "Team McRitchie", user.name
  end

  test "existing bad identity can be repaired from parked wallet claim" do
    wallet = User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:wallet)
    user = User.create!(email: "fresh-admin-wallet@example.com",
                        username: "dawning-cypress",
                        web3_solana_address: wallet)

    assert user.claim_parked_username!
    assert_equal User.parked_username_for(email: "alex@mcritchie.studio"), user.reload.username
    assert_equal "admin", user.role
    assert_equal User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:name), user.name
  end

  test "parked username falls back to generated username when claim is already taken" do
    # The holder must sit on the name this identity actually WANTS, or the
    # fallback never has anything to fall back from — a swap of the parked
    # usernames would otherwise leave this test passing on an empty premise.
    claimed = User.parked_username_for(email: "alex@mcritchie.studio")
    User.create!(email: "holder@example.com", username: claimed)
    wallet = User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:wallet)

    user = User.create!(web3_solana_address: wallet)

    assert user.username.present?
    refute_equal claimed, user.username
    assert_equal "admin", user.role
  end

  test "auto-generated username is capped at the 30-char model limit even when the generator returns a long name" do
    # Studio::UsernameGenerator can emit names longer than 30 chars; ensure
    # ensure_username never produces an invalid (too-long) username, which
    # previously caused intermittent create failures / CI flakes.
    Studio::UsernameGenerator.stub :generate, "fingerlime-pumpkin-rhinoceros-butternut-manatee" do
      user = User.create!(email: "longname@mcritchie.studio")
      assert user.username.length <= 30, "generated username must respect the 30-char limit"
      assert_match(/\A[a-zA-Z0-9_-]+\z/, user.username)
    end
  end

  # Passwordless (Lazarus audit #4): has_secure_password is removed — there is
  # no #authenticate, #password=, or #has_password?. Email auth is magic-link
  # only. The password_digest column is kept dormant (no migration).
  test "password authentication is removed (passwordless)" do
    assert_not User.method_defined?(:authenticate), "User must not respond to #authenticate"
    assert_not User.method_defined?(:password=),     "User must not have a password= setter"
    assert_not User.method_defined?(:has_password?), "has_password? must be removed"
  end

  # H1 (Stage 2 audit): DB-level uniqueness on LOWER(username) closes the
  # signup TOCTOU window. Rails' validation runs in Ruby — two concurrent
  # signups can both pass and both INSERT with the same username. The
  # partial unique index on LOWER(username) makes the second INSERT fail.
  test "username DB unique index rejects case-insensitive duplicate (bypassing Rails validations)" do
    User.create!(email: "h1a@example.com", username: "RaceWinner")

    err = assert_raises(ActiveRecord::RecordNotUnique) do
      # Skip validations to simulate a race: pretend two threads both passed
      # the Ruby-level uniqueness check and tried to INSERT at the same time.
      dup = User.new(email: "h1b@example.com", username: "racewinner")
      dup.save(validate: false)
    end
    assert_match(/index_users_on_lower_username/, err.message)
  end

  test "username DB index permits multiple NULLs (partial WHERE username IS NOT NULL)" do
    # Wallet-only / pre-profile-completion users have nil usernames; the
    # partial WHERE clause must let many of them coexist.
    u1 = User.new(email: "h1c@example.com", username: nil)
    u2 = User.new(email: "h1d@example.com", username: nil)
    assert u1.save(validate: false)
    assert u2.save(validate: false)
  end

  test "email-only user valid without wallet" do
    user = User.new(email: "test@example.com")
    assert user.valid?, user.errors.full_messages.join(", ")
  end

  test "User.valid_email? requires URI::MailTo structure + a real dotted TLD" do
    %w[a@b.co jordan@gmail.com user.name+tag@sub.example.org].each do |ok|
      assert User.valid_email?(ok), "expected #{ok} to be valid"
    end
    [nil, "", "  ", "jordan", "jordan@gmail", "jordan@gmail.c", "jordan@@gmail.com"].each do |bad|
      refute User.valid_email?(bad), "expected #{bad.inspect} to be invalid"
    end
  end

  test "the model rejects a dotless or 1-letter-TLD email (mirrors User.valid_email?)" do
    assert User.new(email: "jordan@gmail").tap(&:valid?).errors[:email].present?
    assert User.new(email: "jordan@gmail.c").tap(&:valid?).errors[:email].present?
    refute User.new(email: "jordan@gmail.com").tap(&:valid?).errors[:email].present?
  end

  test "user invalid with no auth methods" do
    user = User.new
    assert_not user.valid?
    assert user.errors[:base].any? { |e| e.include?("Must have") }
  end

  test "has_email? returns true for email users" do
    assert users(:alex).has_email?
  end

  # entry tokens — refactored to on-chain in turf-vault v0.9.0+. See Solana::Vault#list_entry_tokens.
  # Tests for entry_token_balance now require RPC mocks; skipping until we add VCR/mock harness.

  test "entry_token_balance returns count of unconsumed tokens via Solana::Vault" do
    user = users(:sam) # web3 wallet per fixture
    vault = FakeVault.new(tokens: [
      { pda: "tpda1", consumed: false },
      { pda: "tpda2", consumed: true },
      { pda: "tpda3", consumed: false }
    ])
    Solana::Vault.stub :new, vault do
      assert_equal 2, user.entry_token_balance
    end
  end

  test "entry_token_balance returns 0 for users without a wallet (short-circuit)" do
    user = users(:jordan)
    assert_equal 0, user.entry_token_balance
  end

  test "entry_token_balance returns 0 if Solana::Vault raises" do
    user = users(:sam)
    crashing_vault = Object.new
    def crashing_vault.list_entry_tokens(*); raise "RPC down"; end
    Solana::Vault.stub :new, crashing_vault do
      assert_equal 0, user.entry_token_balance
    end
  end

  # from_omniauth tests

  def google_auth(email: "newgoogle@example.com", name: "Google User", uid: "123456")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: name }
    )
  end

  test "from_omniauth creates new user when no match" do
    auth = google_auth

    assert_difference "User.count", 1 do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal "newgoogle@example.com", user.email
      assert_equal "Google User", user.name
      assert_equal "google_oauth2", user.provider
      assert_equal "123456", user.uid
      assert user.persisted?
      # OPSEC-005: fresh Google signup auto-marks email_verified_at since
      # Google itself asserted the email.
      assert user.email_verified_at.present?
    end
  end

  test "from_omniauth links existing password user by email when verified" do
    alex = users(:alex)
    alex.update!(email_verified_at: Time.current)  # OPSEC-005 precondition
    auth = google_auth(email: alex.email, uid: "99999")

    assert_no_difference "User.count" do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal alex.id, user.id
      assert_equal "google_oauth2", user.provider
      assert_equal "99999", user.uid
    end
  end

  test "from_omniauth refuses silent link when existing user is unverified (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: nil)
    auth = google_auth(email: alex.email, uid: "99999")

    assert_no_difference "User.count" do
      result = User.from_omniauth(auth, email_verified: true)
      assert_equal :requires_verification, result
    end
  end

  test "from_omniauth refuses when caller says Google didn't verify the email (OPSEC-005)" do
    auth = google_auth(uid: "888")
    assert_no_difference "User.count" do
      result = User.from_omniauth(auth, email_verified: false)
      assert_equal :email_not_verified, result
    end
  end

  test "from_omniauth returns existing OAuth user" do
    auth = google_auth(email: "oauth@example.com", uid: "55555")
    original = User.from_omniauth(auth, email_verified: true)

    assert_no_difference "User.count" do
      returning = User.from_omniauth(auth, email_verified: true)
      assert_equal original.id, returning.id
    end
  end

  test "slug is set on save" do
    user = users(:alex)
    user.save!
    assert user.slug.present?
  end

  # --- Seeds (class methods, no DB) ---

  test "level_for returns 1 for 0 seeds" do
    assert_equal 1, User.level_for(0)
  end

  test "level_for returns correct level" do
    assert_equal 1, User.level_for(50)
    assert_equal 2, User.level_for(100)
    assert_equal 4, User.level_for(350)
  end

  test "seeds_toward_next_level returns modulo" do
    assert_equal 0, User.seeds_toward_next_level(0)
    assert_equal 50, User.seeds_toward_next_level(50)
    assert_equal 75, User.seeds_toward_next_level(175)
  end

  test "seeds_progress_percent returns percentage" do
    assert_equal 0, User.seeds_progress_percent(0)
    assert_equal 50, User.seeds_progress_percent(50)
    assert_equal 25, User.seeds_progress_percent(25)
  end

  # --- update_level_from_seeds! ---

  test "update_level_from_seeds! updates level when crossing boundary" do
    user = users(:alex)
    assert_equal 1, user.level
    result = user.update_level_from_seeds!(100)
    assert_equal 2, result
    assert_equal 2, user.reload.level
  end

  test "update_level_from_seeds! returns nil when level unchanged" do
    user = users(:alex)
    assert_equal 1, user.level
    result = user.update_level_from_seeds!(50)
    assert_nil result
    assert_equal 1, user.reload.level
  end

  test "update_level_from_seeds! handles zero seeds" do
    user = users(:alex)
    assert_nil user.update_level_from_seeds!(0)
    assert_equal 1, user.reload.level
  end

  test "update_level_from_seeds! caches the seed total even within a level" do
    user = users(:alex)
    user.update_level_from_seeds!(50)            # still level 1
    assert_equal 50, user.reload.seeds
    assert_equal 1, user.level
    user.update_level_from_seeds!(250)           # crosses to level 3
    assert_equal 250, user.reload.seeds
    assert_equal 3, user.level
  end

  test "update_level_from_seeds! ignores a nil total (cold on-chain read)" do
    user = users(:alex)
    user.update_column(:seeds, 75)
    assert_nil user.update_level_from_seeds!(nil)
    assert_equal 75, user.reload.seeds           # unchanged, no write
  end

  test "update_level_from_seeds! cache write does not bump updated_at" do
    user = users(:alex)
    user.update_column(:seeds, 0)
    before = user.reload.updated_at
    travel_to(1.hour.from_now) { user.update_level_from_seeds!(50) }
    assert_equal 50, user.reload.seeds
    assert_equal before.to_i, user.updated_at.to_i, "cache write should skip updated_at"
  end

  # --- can_change_username? gate ---

  test "can_change_username? false when not solana_connected" do
    user = User.new(email: "bare@example.com")
    user.assign_attributes(web2_solana_address: nil, web3_solana_address: nil, contest_entered: true)
    refute user.can_change_username?
  end

  test "can_change_username? false when solana_connected but contest_entered is false" do
    user = User.new(email: "unentered@example.com")
    user.assign_attributes(web2_solana_address: "wallet_test_abc", contest_entered: false)
    refute user.can_change_username?
  end

  test "can_change_username? true when solana_connected AND contest_entered" do
    user = User.new(email: "ready@example.com")
    user.assign_attributes(web2_solana_address: "wallet_test_xyz", contest_entered: true)
    assert user.can_change_username?
  end
end
