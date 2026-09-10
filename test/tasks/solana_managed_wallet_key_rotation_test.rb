require "test_helper"
require "rake"

# managed-wallet-key-rotation — the regression that makes rotating
# MANAGED_WALLET_ENCRYPTION_KEY unsafe today.
#
# THE DEFECT. Solana::Keypair read ONE key (MANAGED_WALLET_ENCRYPTION_KEY) and
# nothing else, and `solana:reencrypt_managed_wallets` classified a row as
# "done" by its "v2:" PREFIX. After swapping the env var to a new key, every
# row still carries "v2:", so the task skipped them all, printed
# "0 migrated, N already v2, 0 failed" and exited 0 -- while every managed
# wallet secret had become undecryptable. The green run WAS the evidence.
#
# HOW THESE TESTS STAY HONEST.
# - Keys are generated inside the test (SecureRandom.hex(32)) and are throwaway.
#   Nothing here reads, prints or needs a real key.
# - Ciphertexts are sealed and opened by an INDEPENDENT reproduction of the v2
#   envelope below, not by Solana::Keypair, so an assertion that a row "opens
#   under key B" cannot be satisfied by the very code under test.
# - The task is INVOKED, and graded by its exit status (SystemExit#status),
#   never by its summary line.
# - Value comparisons use `assert x == y, msg` so a failure never dumps a
#   decrypted secret into the test log, even a throwaway one.
class SolanaManagedWalletKeyRotationTest < ActiveSupport::TestCase
  KEY_ENV      = "MANAGED_WALLET_ENCRYPTION_KEY".freeze
  PREVIOUS_ENV = "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS".freeze

  # The v2 envelope, restated independently of app/services/solana/keypair.rb:
  # "v2:" + MessageEncryptor(KeyGenerator(material) -> 32-byte key under this
  # label) over the Base64 of the 64-byte Solana secret.
  V2_KDF_LABEL = "turf-monster managed wallet v2".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("solana:reencrypt_managed_wallets")
    @key_a = SecureRandom.hex(32)
    @key_b = SecureRandom.hex(32)
  end

  # --- independent envelope --------------------------------------------------

  def v2_encryptor(material)
    @v2_encryptors ||= {}
    @v2_encryptors[material] ||= ActiveSupport::MessageEncryptor.new(
      ActiveSupport::KeyGenerator.new(material).generate_key(V2_KDF_LABEL, 32)
    )
  end

  def seal(material, keypair)
    "v2:#{v2_encryptor(material).encrypt_and_sign(Base64.strict_encode64(keypair.to_bytes))}"
  end

  # True only when the ciphertext opens under THIS material alone AND carries
  # exactly this keypair's 64-byte secret.
  def opens_under?(material, ciphertext, keypair)
    return false unless ciphertext.to_s.start_with?("v2:")

    plain = v2_encryptor(material).decrypt_and_verify(ciphertext.delete_prefix("v2:"))
    plain == Base64.strict_encode64(keypair.to_bytes)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    false
  end

  # --- environment control -----------------------------------------------------

  # nil VALUE deletes the variable: absent and empty are different states here.
  # Solana::Keypair memoizes the encryptors it derives from ENV, so every class
  # ivar except the admin signer is cleared on the way in AND restored on the
  # way out -- otherwise a memo from an earlier test would answer for the key
  # this test just set, and the assertion would measure the wrong key.
  def with_wallet_keys(primary:, previous: nil)
    saved_env = { KEY_ENV => ENV[KEY_ENV], PREVIOUS_ENV => ENV[PREVIOUS_ENV] }
    memo_ivars = Solana::Keypair.instance_variables - [:@admin]
    saved_memos = memo_ivars.to_h { |iv| [iv, Solana::Keypair.instance_variable_get(iv)] }
    memo_ivars.each { |iv| Solana::Keypair.instance_variable_set(iv, nil) }
    { KEY_ENV => primary, PREVIOUS_ENV => previous }.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
    yield
  ensure
    saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    (Solana::Keypair.instance_variables - [:@admin]).each do |iv|
      Solana::Keypair.instance_variable_set(iv, saved_memos.fetch(iv, nil))
    end
  end

  # --- fixtures ----------------------------------------------------------------

  # A managed-wallet user whose stored secret is sealed under `material`.
  # Created first, then overwritten with update_columns, so whatever wallet the
  # after_create callback minted under the ambient key is replaced.
  def managed_user_sealed_under(material, label)
    keypair = Solana::Keypair.generate
    user = User.create!(name: "Rotation #{label}", email: "rotation-#{label}-#{SecureRandom.hex(3)}@example.test")
    user.update_columns(web2_solana_address: keypair.to_base58,
                        encrypted_web2_solana_private_key: seal(material, keypair))
    [user, keypair]
  end

  def run_task(name = "solana:reencrypt_managed_wallets")
    task = Rake::Task[name]
    task.reenable
    status = 0
    out, = capture_io do
      task.invoke
    rescue SystemExit => e
      status = e.status
    end
    [status, out]
  end

  # --- THE REGRESSION ------------------------------------------------------------

  test "REGRESSION: after rotating A to B, the migration leaves every row readable under B alone" do
    rows = Array.new(3) { |i| managed_user_sealed_under(@key_a, "regress-#{i}") }

    status, = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert status.zero?, "the migration must succeed when every row is migratable (exit #{status})"
    rows.each do |user, keypair|
      assert opens_under?(@key_b, user.reload.encrypted_web2_solana_private_key, keypair),
             "user ##{user.id} must open under the NEW key alone after the migration"
    end
  end

  test "REGRESSION: swapping the key with no old key configured is a FAILED run, never a green one" do
    rows = Array.new(2) { |i| managed_user_sealed_under(@key_a, "swap-#{i}") }

    status, = with_wallet_keys(primary: @key_b, previous: nil) { run_task }

    assert status.nonzero?, "a run that left rows unreadable under the current key must exit non-zero"
    rows.each do |user, keypair|
      assert opens_under?(@key_a, user.reload.encrypted_web2_solana_private_key, keypair),
             "user ##{user.id} must be left untouched -- still sealed under the old key"
    end
  end

  # --- counts, idempotence -------------------------------------------------------

  test "prints total / migrated / already-new / failed and verifies every row by recount" do
    managed_user_sealed_under(@key_a, "count-old-1")
    managed_user_sealed_under(@key_a, "count-old-2")
    managed_user_sealed_under(@key_b, "count-new")

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 0, status
    assert_match(/total: 3  migrated: 2  already-new: 1  failed: 0/, out)
    assert_match(/Read-back: 3 of 3 row\(s\) open under the current key alone/, out)
    assert_match(/^COMPLETE/, out)
  end

  test "a row already under the new key is not rewritten" do
    user, = managed_user_sealed_under(@key_b, "already")
    before = user.encrypted_web2_solana_private_key

    status, = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 0, status
    assert user.reload.encrypted_web2_solana_private_key == before, "an already-new row must be left byte-identical"
  end

  test "a second run after a complete one changes nothing and still exits 0" do
    rows = Array.new(2) { |i| managed_user_sealed_under(@key_a, "twice-#{i}") }
    with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }
    after_first = rows.map { |u, _| u.reload.encrypted_web2_solana_private_key }

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 0, status
    assert_match(/total: 2  migrated: 0  already-new: 2  failed: 0/, out)
    assert rows.map { |u, _| u.reload.encrypted_web2_solana_private_key } == after_first,
           "a re-run must not touch rows that are already done"
  end

  # --- resume after a crash --------------------------------------------------------

  # A crash is a non-StandardError escaping mid-walk (a killed dyno, a Ctrl-C):
  # the per-row rescue must NOT swallow it. Rows already written stay new, the
  # rest stay old, both keys still open both, and a re-run finishes the job.
  test "a run that dies halfway leaves every row readable, and a re-run finishes it" do
    rows = Array.new(4) { |i| managed_user_sealed_under(@key_a, "crash-#{i}") }
    real_seal = Solana::Keypair.method(:seal_plaintext)
    seals = 0
    crashing_seal = lambda do |plaintext|
      seals += 1
      raise Interrupt, "simulated crash" if seals == 3

      real_seal.call(plaintext)
    end

    with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, crashing_seal) do
        assert_raises(Interrupt) { capture_io { Rake::Task["solana:reencrypt_managed_wallets"].tap(&:reenable).invoke } }
      end

      states = rows.map do |user, keypair|
        ciphertext = user.reload.encrypted_web2_solana_private_key
        if opens_under?(@key_b, ciphertext, keypair) then :new
        elsif opens_under?(@key_a, ciphertext, keypair) then :old
        else :broken
        end
      end
      assert_equal %i[new new old old], states, "the crash must leave whole rows: two done, two untouched, none broken"
      rows.each do |user, keypair|
        assert Solana::Keypair.from_encrypted(user.encrypted_web2_solana_private_key).to_bytes == keypair.to_bytes,
               "every row must stay readable by the app mid-rotation"
      end
    end

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 0, status
    assert_match(/total: 4  migrated: 2  already-new: 2  failed: 0/, out)
    rows.each do |user, keypair|
      assert opens_under?(@key_b, user.reload.encrypted_web2_solana_private_key, keypair)
    end
  end

  # --- read-back verification ------------------------------------------------------

  test "a row whose re-seal the current key cannot read back stays on the old key and is reported" do
    good, good_kp = managed_user_sealed_under(@key_a, "verify-good")
    bad, bad_kp = managed_user_sealed_under(@key_a, "verify-bad")
    bad_plaintext = Base64.strict_encode64(bad_kp.to_bytes)
    rogue = SecureRandom.hex(32)
    real_seal = Solana::Keypair.method(:seal_plaintext)
    # For the bad row only, the "fresh" ciphertext is sealed under a key the app
    # does not hold -- the exact thing the read-back exists to catch.
    sabotaged_seal = lambda do |plaintext|
      if plaintext == bad_plaintext
        "v2:#{v2_encryptor(rogue).encrypt_and_sign(plaintext)}"
      else
        real_seal.call(plaintext)
      end
    end

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, sabotaged_seal) { run_task }
    end

    assert_equal 1, status, "a row not migrated and verified must fail the run"
    assert opens_under?(@key_a, bad.reload.encrypted_web2_solana_private_key, bad_kp),
           "the unverified row must stay sealed under the old key"
    assert opens_under?(@key_b, good.reload.encrypted_web2_solana_private_key, good_kp),
           "one bad row must not stop the others"
    assert_match(/FAILED user ##{bad.id} .*read-back under the current key alone did not match/, out)
    assert_match(/total: 2  migrated: 1  already-new: 0  failed: 1/, out)
    assert_match(/^NOT COMPLETE/, out)
    assert ErrorLog.where(target_type: "User", target_id: bad.id).exists?, "the failure must leave a durable ErrorLog"
  end

  test "a re-seal that reads back to a DIFFERENT secret stays on the old key" do
    user, keypair = managed_user_sealed_under(@key_a, "verify-swap")
    impostor = Base64.strict_encode64(Solana::Keypair.generate.to_bytes)
    real_seal = Solana::Keypair.method(:seal_plaintext)

    status, = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, ->(_plaintext) { real_seal.call(impostor) }) { run_task }
    end

    assert_equal 1, status
    assert opens_under?(@key_a, user.reload.encrypted_web2_solana_private_key, keypair),
           "a re-seal carrying any other secret must never be written"
  end

  # "Decrypt it with the new key ALONE." A re-seal that landed under the
  # PREVIOUS key would pass any read-back that also tries the previous key --
  # and then die the day that key is retired. It must be refused, and the row
  # left exactly as it was.
  test "a re-seal that only the PREVIOUS key can open is refused and never written" do
    user, keypair = managed_user_sealed_under(@key_a, "verify-prev")
    before = user.encrypted_web2_solana_private_key

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, ->(plaintext) { "v2:#{v2_encryptor(@key_a).encrypt_and_sign(plaintext)}" }) do
        run_task
      end
    end

    assert_equal 1, status
    assert_match(/FAILED user ##{user.id} .*read-back under the current key alone did not match/, out)
    assert_match(/migrated: 0/, out)
    assert user.reload.encrypted_web2_solana_private_key == before, "the row must be left byte-identical"
    assert opens_under?(@key_a, before, keypair)
  end

  # The address check cannot see this one: Solana::Keypair.from_bytes reads
  # only the 32-byte seed, so a plaintext with the SAME seed and a different
  # second half derives the same address. Only the byte-for-byte comparison
  # against the original plaintext refuses it.
  test "a re-seal that differs from the original only where the address cannot see is still refused" do
    user, keypair = managed_user_sealed_under(@key_a, "verify-tail")
    tail_swapped = Base64.strict_encode64(keypair.to_bytes[0, 32] + SecureRandom.random_bytes(32))
    real_seal = Solana::Keypair.method(:seal_plaintext)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, ->(_plaintext) { real_seal.call(tail_swapped) }) { run_task }
    end

    assert_equal 1, status
    assert_match(/read-back under the current key alone did not match/, out)
    assert opens_under?(@key_a, user.reload.encrypted_web2_solana_private_key, keypair),
           "the exact original bytes must survive, not merely the address"
  end

  # The walk's own bookkeeping is not the last word: an independent recount of
  # every row under the current key alone must agree, or the run is not green.
  test "the run exits 1 when the independent recount disagrees with the walk" do
    managed_user_sealed_under(@key_a, "recount-1")
    managed_user_sealed_under(@key_a, "recount-2")
    short = Solana::ManagedWalletRotation::CheckResult.new(total: 2, current: 1, previous: 1, legacy: 0,
                                                           wrong_wallet: 0, unreadable: 0)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::ManagedWalletRotation.stub(:check, short) { run_task }
    end

    assert_equal 1, status, "a recount short of the total must fail the run even when no row failed"
    assert_match(/failed: 0/, out)
    assert_match(/^NOT COMPLETE/, out)
  end

  test "a row whose secret does not derive its stored address is reported, not migrated" do
    user, keypair = managed_user_sealed_under(@key_a, "wrong-wallet")
    user.update_columns(web2_solana_address: Solana::Keypair.generate.to_base58)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 1, status
    assert_match(/FAILED user ##{user.id}.*does not derive its stored wallet address/, out)
    assert opens_under?(@key_a, user.reload.encrypted_web2_solana_private_key, keypair)
  end

  test "a row that changed underneath the migration is never clobbered" do
    user, = managed_user_sealed_under(@key_a, "cas")
    concurrent = seal(@key_b, Solana::Keypair.generate)
    real_seal = Solana::Keypair.method(:seal_plaintext)
    racing_seal = lambda do |plaintext|
      User.where(id: user.id).update_all(encrypted_web2_solana_private_key: concurrent)
      real_seal.call(plaintext)
    end

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      Solana::Keypair.stub(:seal_plaintext, racing_seal) { run_task }
    end

    assert_equal 1, status
    assert user.reload.encrypted_web2_solana_private_key == concurrent, "a concurrent write must survive"
    assert_match(/row changed during the migration/, out)
  end

  test "a stray pre-OPSEC-015 legacy row is re-sealed under the new key during a rotation" do
    keypair = Solana::Keypair.generate
    user = User.create!(name: "Rotation legacy", email: "rotation-legacy-#{SecureRandom.hex(3)}@example.test")
    legacy_material = Rails.application.credentials.secret_key_base.presence || Solana::Keypair::TEST_SECRET_KEY_BASE
    legacy = ActiveSupport::MessageEncryptor.new(legacy_material[0, 32])
                                            .encrypt_and_sign(Base64.strict_encode64(keypair.to_bytes))
    user.update_columns(web2_solana_address: keypair.to_base58, encrypted_web2_solana_private_key: legacy)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }

    assert_equal 0, status
    assert_match(/\(migrated: 0 from the previous key, 1 from the legacy scheme\)/, out)
    assert opens_under?(@key_b, user.reload.encrypted_web2_solana_private_key, keypair)
  end

  # --- dry run ---------------------------------------------------------------------

  test "the dry run counts what it would do and writes nothing" do
    rows = Array.new(3) { |i| managed_user_sealed_under(@key_a, "dry-#{i}") }
    before = rows.map { |u, _| u.encrypted_web2_solana_private_key }

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      with_dry_run { assert_no_difference(-> { ErrorLog.count }) { run_task_result } }
    end

    assert_equal 0, status
    assert_match(/DRY RUN -- nothing will be written/, out)
    assert_match(/total: 3  would-migrate: 3  already-new: 0  failed: 0/, out)
    assert_match(/would-migrate: 3 from the previous key/, out)
    assert rows.map { |u, _| u.reload.encrypted_web2_solana_private_key } == before, "a dry run must write nothing"
  end

  test "the dry run fails, and still writes nothing, when a row does not open under the old key" do
    managed_user_sealed_under(@key_a, "dry-ok")
    stray, = managed_user_sealed_under(SecureRandom.hex(32), "dry-stray")
    before = User.where.not(encrypted_web2_solana_private_key: [nil, ""]).order(:id)
                 .pluck(:encrypted_web2_solana_private_key)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      with_dry_run { assert_no_difference(-> { ErrorLog.count }) { run_task_result } }
    end

    assert_equal 1, status, "a dry run that finds an unmigratable row must not read as clean"
    assert_match(/FAILED user ##{stray.id}.*opens under no configured key/, out)
    assert_match(/DRY RUN FOUND 1 ROW/, out)
    assert User.where.not(encrypted_web2_solana_private_key: [nil, ""]).order(:id)
               .pluck(:encrypted_web2_solana_private_key) == before
  end

  # --- refusals: exit 2, nothing read or written -------------------------------------

  {
    "the new key is absent"             => ->(t) { [nil, t.key_a] },
    "the new key is malformed"          => ->(t) { [t.key_b[0, 40], t.key_a] },
    "the new key has a trailing newline" => ->(t) { ["#{t.key_b}\n", t.key_a] },
    "the new key equals the old key"    => ->(t) { [t.key_a, t.key_a] },
    "the old key is set but empty"      => ->(t) { [t.key_b, ""] }
  }.each do |condition, keys|
    test "refuses to start when #{condition}" do
      rows = Array.new(2) { |i| managed_user_sealed_under(@key_a, "refuse-#{i}") }
      before = rows.map { |u, _| u.encrypted_web2_solana_private_key }
      primary, previous = keys.call(self)

      status, out = with_wallet_keys(primary: primary, previous: previous) { run_task }

      assert_equal 2, status, "a refused configuration must exit 2"
      assert_match(/^REFUSED/, out)
      assert rows.map { |u, _| u.reload.encrypted_web2_solana_private_key } == before, "a refusal must write nothing"
      [@key_a, @key_b].each { |k| assert_not out.include?(k), "a refusal must never print a key" }
    end
  end

  # --- secrets never leave memory -----------------------------------------------------

  test "no key, plaintext or secret appears in the output or the ErrorLog rows" do
    rows = Array.new(2) { |i| managed_user_sealed_under(@key_a, "secret-#{i}") }
    stray, stray_kp = managed_user_sealed_under(SecureRandom.hex(32), "secret-stray")
    wrong, wrong_kp = managed_user_sealed_under(@key_a, "secret-wrong")
    wrong.update_columns(web2_solana_address: Solana::Keypair.generate.to_base58)

    status, out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }
    dry_status, dry_out = with_wallet_keys(primary: @key_b, previous: @key_a) { with_dry_run { run_task_result } }
    _, check_out = with_wallet_keys(primary: @key_b, previous: @key_a) { run_task("solana:verify_managed_wallet_keys") }

    assert_equal 1, status
    assert_equal 1, dry_status
    logs = ErrorLog.where(target_type: "User", target_id: [stray.id, wrong.id])
    assert_equal 2, logs.count, "each failed row leaves one ErrorLog"
    recorded = logs.flat_map { |l| [l.message, l.inspect_field, l.backtrace] }.join("\n")
    haystack = [out, dry_out, check_out, recorded].join("\n")

    secrets = [@key_a, @key_b]
    (rows.map(&:last) + [stray_kp, wrong_kp]).each do |kp|
      secrets << Base64.strict_encode64(kp.to_bytes)
      secrets << Solana::Keypair.encode_base58(kp.to_bytes)
      secrets << kp.to_bytes.unpack1("H*")
    end
    secrets.each { |s| assert_not haystack.include?(s), "a key or secret leaked into output or ErrorLog" }
  end

  # --- the read-only verifier ---------------------------------------------------------

  test "verify_managed_wallet_keys counts rows, exits 1 while any row needs the old key, 0 after" do
    managed_user_sealed_under(@key_a, "check-old")
    managed_user_sealed_under(@key_b, "check-new")

    before_status, before_out = with_wallet_keys(primary: @key_b, previous: @key_a) do
      run_task("solana:verify_managed_wallet_keys")
    end
    with_wallet_keys(primary: @key_b, previous: @key_a) { run_task }
    # The previous key retired: the proof must not lean on it.
    after_status, after_out = with_wallet_keys(primary: @key_b, previous: nil) do
      run_task("solana:verify_managed_wallet_keys")
    end

    assert_equal 1, before_status
    assert_match(/total: 2  current-key: 1  still-previous-key: 1/, before_out)
    assert_match(/^NOT VERIFIED/, before_out)
    assert_equal 0, after_status
    assert_match(/total: 2  current-key: 2  still-previous-key: 0/, after_out)
    assert_match(/^VERIFIED -- 2 of 2/, after_out)
  end

  test "verify_managed_wallet_keys writes nothing" do
    rows = Array.new(2) { |i| managed_user_sealed_under(@key_a, "check-ro-#{i}") }
    before = rows.map { |u, _| u.encrypted_web2_solana_private_key }

    with_wallet_keys(primary: @key_b, previous: @key_a) do
      assert_no_difference(-> { ErrorLog.count }) { run_task("solana:verify_managed_wallet_keys") }
    end

    assert rows.map { |u, _| u.reload.encrypted_web2_solana_private_key } == before
  end

  attr_reader :key_a, :key_b

  private

  def with_dry_run
    had = ENV.key?("DRY_RUN")
    previous = ENV["DRY_RUN"]
    ENV["DRY_RUN"] = "1"
    yield
  ensure
    had ? ENV["DRY_RUN"] = previous : ENV.delete("DRY_RUN")
  end

  # run_task, for use inside a block whose value is the task's result.
  def run_task_result(name = "solana:reencrypt_managed_wallets") = run_task(name)
end
