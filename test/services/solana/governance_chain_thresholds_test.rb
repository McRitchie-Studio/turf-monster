require "test_helper"

# On v0.26 the threshold a builder sizes its cosigner slots by is the one the
# chain stores in GovernanceConfig, not the compiled default. On v0.25 nothing
# is read and nothing changes.
#
# Card 12 retunes devnet settle from 3 to 2. With the compiled default the
# unattended settle demanded a third key the chain no longer wants; these tests
# hold the app to the chain's number.
class Solana::GovernanceChainThresholdsTest < ActiveSupport::TestCase
  ID = Solana::Governance::ACTION_IDS

  # A 32-byte stored table: zeros (unset) except the given retunes.
  def table(retunes = {})
    Array.new(32, 0).tap { |t| retunes.each { |action, value| t[ID.fetch(action)] = value } }
  end

  def admin = Solana::Keypair.admin

  def key(n) = Solana::Keypair.from_bytes(Digest::SHA256.digest("chain-threshold signer #{n}"))

  # A vault whose GovernanceConfig read answers `governance`, and which fails
  # the test if v0.25 code reaches for the chain at all.
  def vault_with(governance, reads: [])
    Solana::Vault.new(client: Object.new).tap do |v|
      v.define_singleton_method(:cached_governance) { reads << :governance; governance }
    end
  end

  # ── The pure rule: GovernanceConfig::threshold_for ──────────────────────

  test "a stored value replaces the default" do
    assert_equal 2, Solana::Governance.required_signatures("settle_contest", thresholds: table("settle_contest" => 2))
    assert_equal 3, Solana::Governance.required_signatures("close_contest", thresholds: table("close_contest" => 3))
  end

  test "a stored zero reads as the shipped default" do
    assert_equal 3, Solana::Governance.required_signatures("settle_contest", thresholds: table)
    assert_equal 2, Solana::Governance.required_signatures("close_contest", thresholds: table)
  end

  test "a stored value below a floor reads as the floor" do
    assert_equal 3, Solana::Governance.required_signatures("update_signers", thresholds: table("update_signers" => 1))
  end

  # A table written before the registry existed stores a literal 1 at 22-24.
  test "the username registry actions are 22-24, three, and floored at three" do
    assert_equal({ "overwrite_username" => 22, "reserve_username" => 23, "release_reserved_username" => 24 },
                 ID.slice("overwrite_username", "reserve_username", "release_reserved_username"))

    stale = Array.new(32, 1)
    %w[overwrite_username reserve_username release_reserved_username].each do |action|
      assert_equal 3, Solana::Governance.required_signatures(action)
      assert_equal 3, Solana::Governance.required_signatures(action, thresholds: stale)
    end
  end

  test "max_live_threshold follows a retune above three" do
    assert_equal 3, Solana::Governance.max_live_threshold(table)
    assert_equal 4, Solana::Governance.max_live_threshold(table("settle_contest" => 4))
  end

  # ── Vault#required_signatures: chain on v0.26, constants on v0.25 ──────

  test "on v0.26 the vault answers with the stored table" do
    vault = vault_with({ thresholds: table("settle_contest" => 2, "close_contest" => 3) })

    Solana::Config.stub(:governance?, true) do
      assert_equal 2, vault.required_signatures("settle_contest")
      assert_equal 3, vault.required_signatures("close_contest")
      assert_equal 3, vault.required_signatures("cancel_contest"), "an unset entry is still the default"
    end
  end

  test "on v0.26 an unreadable GovernanceConfig falls back to the defaults" do
    Solana::Config.stub(:governance?, true) do
      assert_equal 3, vault_with(nil).required_signatures("settle_contest")
    end
  end

  test "on v0.25 the vault answers with constants and never reads the chain" do
    reads = []
    vault = vault_with({ thresholds: table("settle_contest" => 2) }, reads: reads)

    Solana::Config.stub(:governance?, false) do
      assert_equal 3, vault.required_signatures("settle_contest")
      assert_empty vault.unattended_extra_signer_metas("settle_contest", signers: [])
    end
    assert_empty reads
  end

  # The unattended settle names admin + cosigner. At the default 3 that is one
  # short; after a retune to 2 it is enough, and no third key is asked for.
  test "the unattended settle accepts two keys once the chain says two" do
    cosigner = key(1)
    named = [admin.public_key_bytes, cosigner.public_key_bytes]

    Solana::Config.stub(:governance?, true) do
      assert_raises(Solana::Vault::ThresholdUnreachableError) do
        vault_with({ thresholds: table }).unattended_extra_signer_metas("settle_contest", signers: [], named: named)
      end

      assert_empty vault_with({ thresholds: table("settle_contest" => 2) })
        .unattended_extra_signer_metas("settle_contest", signers: [], named: named)
    end
  end

  test "a close retuned to three refuses a server plus one agent" do
    Solana::Config.stub(:governance?, true) do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) do
        vault_with({ thresholds: table("close_contest" => 3) })
          .unattended_extra_signer_metas("close_contest", signers: [key(1)])
      end
      assert_match(/close_contest needs 3 vault signatures/, error.message)
    end
  end

  # ── The escalated contest-time actions read the contest account ─────────

  def vault_with_contest(lock:, conclusion: 0)
    Solana::Vault.new(client: Object.new).tap do |v|
      v.define_singleton_method(:read_contest) { |_slug| { lock_timestamp: lock, conclusion_timestamp: conclusion } }
    end
  end

  test "a lock that has passed on chain is the reopen action" do
    now = Time.zone.at(1_900_000_000)
    assert_equal "set_contest_lock_time_reopen",
                 vault_with_contest(lock: now.to_i - 60).contest_time_action("set_contest_lock_time", "c", now: now)
    assert_equal "set_contest_lock_time",
                 vault_with_contest(lock: now.to_i + 60).contest_time_action("set_contest_lock_time", "c", now: now)
    assert_equal "set_contest_lock_time",
                 vault_with_contest(lock: 0).contest_time_action("set_contest_lock_time", "c", now: now)
  end

  test "a conclusion already set is the amend action" do
    assert_equal "set_contest_conclusion_time_amend",
                 vault_with_contest(lock: 0, conclusion: 1_900_000_000).contest_time_action("set_contest_conclusion_time", "c")
    assert_equal "set_contest_conclusion_time",
                 vault_with_contest(lock: 0).contest_time_action("set_contest_conclusion_time", "c")
  end

  test "v0.25 picks the base action without reading the contest" do
    vault = Solana::Vault.new(client: Object.new)
    vault.define_singleton_method(:read_contest) { |_slug| flunk "v0.25 must not read the contest" }

    Solana::Config.stub(:governance?, false) do
      assert_equal "set_contest_lock_time", vault.governed_time_action("set_contest_lock_time", "c")
    end
  end
end
