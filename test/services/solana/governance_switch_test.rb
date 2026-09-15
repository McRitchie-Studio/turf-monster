require "test_helper"

# The v0.25 <-> v0.26 switch itself: how it parses, what it selects, how it
# refuses, and the two derivations that have to agree byte-for-byte with code
# living in another repo.
#
# WHY A SWITCH AT ALL. turf-vault v0.26 changes the ACCOUNT LIST of every
# vault-authorized instruction, so the two shapes are mutually unintelligible
# on-chain: a v0.26 wire sent to the live v0.25 program is rejected, and a v0.25
# wire sent to an upgraded program is rejected too. "Update Rails first" and
# "upgrade the program first" are therefore the same outage in opposite
# directions. Carrying both shapes and choosing at boot is what turns the
# changeover from a deploy into a config write, and the rollback from a second
# multisig ceremony into a dyno restart.
class Solana::GovernanceSwitchTest < ActiveSupport::TestCase
  CONFIG_RB = Rails.root.join("app", "services", "solana", "config.rb")

  # The constant is frozen at class-load from ENV, so the parse is re-derived
  # here from the same source of truth rather than by re-booting the app under a
  # different environment. The vocabulary lists ARE the contract.
  def resolve(value, present: true)
    return false unless present

    raw = value.to_s.strip.downcase
    return true if Solana::Config::GOVERNANCE_TRUE.include?(raw)
    return false if Solana::Config::GOVERNANCE_FALSE.include?(raw)
    raise ArgumentError, "unreadable"
  end

  # ── THE DEFAULT IS THE DEPLOYED SHAPE ─────────────────────────────────────

  test "an ABSENT switch resolves to the v0.25 shape, which is what is deployed" do
    refute resolve(nil, present: false),
           "the default must match the program actually on chain, or this PR is an outage on its own"
  end

  test "this build ships resolved to v0.25" do
    refute Solana::Config.governance?,
           "the merge-time default must stay v0.25 until the Squads upgrade lands"
    assert_equal "v0.25", Solana::Config.vault_shape
  end

  test "the affirmative vocabulary turns the v0.26 shape on" do
    %w[on 1 true yes enabled ON True YES].each do |v|
      assert resolve(v), "#{v.inspect} should select v0.26"
    end
  end

  test "the negative vocabulary keeps the v0.25 shape" do
    %w[off 0 false no disabled OFF False].each do |v|
      refute resolve(v), "#{v.inspect} should select v0.25"
    end
  end

  # THE FOOTGUN THIS CLOSES, and it is the one this codebase has already been
  # burned by: SOLANA_NETWORK shipped as `ENV.fetch(k, default)`, whose BLOCK and
  # default forms both fire only on ABSENCE — so a single `heroku config:set
  # SOLANA_NETWORK=` walked straight past the guard. Present-but-unreadable must
  # be a different outcome from absent, or a typo silently means "off" on exactly
  # the day someone meant to turn it on.
  test "a present-but-GARBAGE value raises instead of defaulting" do
    ["yeah", "1.0", "enable", "v0.26", "-", "ok"].each do |v|
      assert_raises(ArgumentError, "#{v.inspect} must refuse, not default") { resolve(v) }
    end
  end

  test "a present-but-EMPTY value raises rather than resolving like absent" do
    assert_raises(ArgumentError) { resolve("") }
    assert_raises(ArgumentError) { resolve("   ") }
    refute resolve("", present: false), "absent is still the documented default"
  end

  test "the config reads presence with ENV.key?, which is what tells absent from empty" do
    source = CONFIG_RB.read
    assert_match(/if !ENV\.key\?\(GOVERNANCE_ENV_VAR\)/, source,
                 "ENV.fetch with a default cannot distinguish absent from set-but-empty")
  end

  # ── WHAT THE SWITCH SELECTS ───────────────────────────────────────────────

  test "all four IDL artifacts exist and differ only as cluster x version" do
    devnet_25 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.idl.json")))
    devnet_26 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json")))
    mainnet_25 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.mainnet.idl.json")))
    mainnet_26 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.mainnet.v026.idl.json")))

    assert_equal devnet_25["address"], devnet_26["address"], "both devnet artifacts pin the devnet program"
    assert_equal mainnet_25["address"], mainnet_26["address"], "both mainnet artifacts pin the mainnet program"
    refute_equal devnet_25["address"], mainnet_25["address"], "the clusters run SEPARATE program IDs"

    # Cluster pairs must be identical apart from the address, which is the
    # property that makes "two files per version" honest rather than a fork.
    assert_equal devnet_26.except("address"), mainnet_26.except("address")
    assert_equal devnet_25.except("address"), mainnet_25.except("address")
  end

  test "the v0.25 IDLs are untouched by this change, so today's boot is unaffected" do
    # Pinned hashes. If a future change edits these files, the production
    # EXPECTED_IDL_HASH stops matching and the app refuses to boot — so the
    # numbers belong in a test, not only in a runbook.
    assert_equal "f11446facec1043cb15b169929aaff3da9e955e05f3c462e86c7b584706246e9",
                 Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.idl.json")))
    assert_equal "b9b522635894a42f5434f1faa1cd126d146f3042ae2c233acd1dd76a300f7152",
                 Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.idl.json")))
  end

  # The values an operator pastes into `heroku config:set` during the upgrade
  # window. Re-pinned from the FRESHLY BUILT IDL (anchor-cli 0.32.1,
  # `anchor idl build`), never from `anchor idl fetch` — a Squads deploy does
  # not update the on-chain IDL, so a fetch would return the OLD one and the pin
  # would certify the wrong shape.
  test "the v0.26 IDL hashes match what the runbook tells the operator to pin" do
    assert_equal "259889ced686875b46062aaabce7e8c45e68710e6c0ae0738f3451cd4673060f",
                 Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.v026.idl.json"))),
                 "devnet v0.26 hash drifted from docs/SOLANA.md"
    assert_equal "d1eea2a48d0a7f0cf711d3da7c85a1653d13e0903be6bebcf7be47be41404ea7",
                 Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.v026.idl.json"))),
                 "mainnet v0.26 hash drifted from docs/SOLANA.md"
  end

  # ── THE DISCRIMINATOR IS STRUCTURAL, NOT A VERSION STRING ─────────────────
  #
  # This is the trap. turf-vault built v0.26 with `version = "0.25.0"` still in
  # programs/turf_vault/Cargo.toml, so BOTH IDLs report metadata.version
  # "0.25.0". Anything keying on that string would have looked correct, passed
  # review, and selected the wrong shape in production.
  test "metadata.version is IDENTICAL across the two shapes and cannot discriminate" do
    v25 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.idl.json"))).dig("metadata", "version")
    v26 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json"))).dig("metadata", "version")

    assert_equal v25, v26,
                 "if turf-vault finally bumps its Cargo version, this test is the place that says so"
    assert_equal "0.25.0", v26, "the v0.26 IDL still reports 0.25.0 — an unbumped Cargo.toml"
  end

  test "the structural probe tells the two IDLs apart" do
    v25 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.idl.json")))
                .fetch("instructions").map { |i| i["name"] }
    v26 = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json")))
                .fetch("instructions").map { |i| i["name"] }

    refute_includes v25, "init_governance"
    assert_includes v26, "init_governance"

    # And the app's own probe reads the file it actually selected.
    assert_equal Solana::Config.governance?, Solana::Config.idl_declares_governance?,
                 "the switch and the pinned IDL must agree, or verify_governance_alignment! refuses the boot"
  end

  test "the v0.26 IDL carries the full 6000-6066 error range and the new accounts" do
    idl = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json")))
    codes = idl.fetch("errors").map { |e| e["code"] }

    assert_equal 6000, codes.min
    assert_equal 6066, codes.max
    assert_equal 67, codes.length, "6000..6066 inclusive is 67 variants"

    accounts = idl.fetch("accounts").map { |a| a["name"] }
    %w[GovernanceConfig MintWindow UsernameRecord].each { |a| assert_includes accounts, a }
  end

  # ── THE ALIGNMENT GUARD ───────────────────────────────────────────────────
  #
  # The switch says one shape, the file on disk is the other. Reachable by a bad
  # copy, a half-applied revert, or a hand-edited IDL — every one of which ends
  # with Rails assembling account lists for a program shape other than the one
  # this slug believes is deployed.

  test "a switch that disagrees with the pinned IDL refuses, naming both sides" do
    # This build is resolved to v0.25; pretend the selected file is the v0.26 one.
    Solana::Config.stub(:idl_declares_governance?, true) do
      error = assert_raises(Solana::Config::GovernanceMismatchError) do
        Solana::Config.verify_governance_alignment!
      end

      assert_match(/SOLANA_VAULT_GOVERNANCE/, error.message)
      assert_match(/declares init_governance: true/, error.message)
      assert_match(/turf_vault\.idl\.json/, error.message, "the message must name the file it read")
      assert_match(/Do NOT set\s+BYPASS_IDL_CHECK/m, error.message,
                   "the hash bypass is not an escape hatch for a wrong SHAPE")
    end
  end

  test "an agreeing pair passes silently" do
    assert_nil Solana::Config.verify_governance_alignment!
  end

  # A missing or corrupt IDL is verify_idl!'s failure to report, not this one's —
  # two raises for one cause would bury the informative one.
  test "the alignment check stays quiet when the IDL cannot be read at all" do
    Solana::Config.stub(:idl_instruction_names, []) do
      assert_nil Solana::Config.verify_governance_alignment!
    end
  end

  # ── THE USERNAME KEY, HELD AGAINST ITS OFF-CHAIN TWIN ─────────────────────
  #
  # The registry key is the uniqueness rule: two names collide exactly when this
  # returns the same bytes. turf-vault's canonical_username_key folds with
  # `u8::to_ascii_lowercase` per byte, and scripts/lib/username-key.js folds the
  # same byte RANGE — deliberately not String.toLowerCase(), so a non-ASCII
  # character the program leaves alone is left alone here too.
  def vault = Solana::Vault.new(client: Object.new)

  test "the canonical key is the 32-byte buffer with ASCII A-Z folded" do
    key = vault.username_name_key("Alice")
    assert_equal 32, key.bytesize
    assert_equal "alice", key[0, 5]
    assert_equal "\x00".b * 27, key[5, 27], "the tail must be zero PADDING, not spaces"
  end

  test "case-only variants are ONE name, which is what makes the registry a lock" do
    %w[alice Alice ALICE aLiCe].each do |variant|
      assert_equal vault.username_name_key("alice"), vault.username_name_key(variant)
    end
    refute_equal vault.username_name_key("alice"), vault.username_name_key("alicia")
  end

  # THE ASCII-ONLY FOLD, and the reason it is a byte range in the source. Ruby's
  # String#downcase is Unicode-aware and folds "É" to "é"; the program's
  # to_ascii_lowercase does not. Using downcase would derive a DIFFERENT record
  # than the program writes — unreachable today because the on-chain charset bar
  # refuses every byte outside 0x20..0x7E, and reachable the moment that bar is
  # widened.
  test "only ASCII is folded, matching the program byte for byte" do
    folded = vault.username_name_key("ÉCLAIR")
    naive = "ÉCLAIR".downcase.b

    refute_equal naive, folded[0, naive.bytesize],
                 "String#downcase would fold É and diverge from canonical_username_key"
    assert_equal "\xC3\x89".b, folded[0, 2], "the non-ASCII bytes must survive untouched"
    assert_equal "clair", folded[2, 5], "the ASCII tail is still folded"
  end

  test "the record PDA is seeded on the FULL 32 bytes, padding included" do
    program_id = Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)
    expected, _ = Solana::Transaction.find_pda(
      ["username".b, vault.username_name_key("alice")], program_id
    )
    actual, _ = vault.username_record_pda("alice")
    assert_equal expected, actual

    # A seed of only the significant bytes would derive a different address —
    # the mistake worth pinning, because both derivations look reasonable.
    truncated, _ = Solana::Transaction.find_pda(["username".b, "alice".b], program_id)
    refute_equal truncated, actual, "the seed is the padded buffer, not the trimmed name"
  end

  # ── THE MINT WINDOW ───────────────────────────────────────────────────────

  test "the window index is floor division, agreeing with Rust div_euclid" do
    v = vault
    v.stub(:cached_governance, { mint_window_seconds: 86_400, mint_window_cap: 250 }) do
      assert_equal 0, v.mint_window_index(Time.at(0))
      assert_equal 0, v.mint_window_index(Time.at(86_399))
      assert_equal 1, v.mint_window_index(Time.at(86_400))
      assert_equal 20_346, v.mint_window_index(Time.utc(2025, 9, 15, 12))

      # div_euclid FLOORS toward negative infinity; Ruby's Integer#div does the
      # same, while `/` on the Float path and C-style truncation do not. Only
      # reachable for pre-1970 timestamps, pinned because the two disagree
      # exactly where nobody looks.
      assert_equal(-1, v.mint_window_index(Time.at(-1)))
      assert_equal(-2, v.mint_window_index(Time.at(-86_401)))
    end
  end

  test "the window length is read from chain, not baked in" do
    v = vault
    v.stub(:cached_governance, { mint_window_seconds: 3_600, mint_window_cap: 10 }) do
      assert_equal 2, v.mint_window_index(Time.at(7_200)),
                   "a retuned policy must move the index, or every mint fails MintWindowMismatch"
    end
  end

  # THE SEEDS THEMSELVES, spelled out. `mint_window_pda(i)` compared against
  # itself would pass with any seed string at all; these pin the literal bytes
  # against turf-vault's `seeds = [b"mint_window", window_index.to_le_bytes()]`
  # and `seeds = [b"governance"]`. A PDA derived from the wrong seed is a valid
  # address that simply does not exist, so the failure would be an opaque
  # AccountNotInitialized rather than anything naming the seed.
  test "the mint-window PDA is seeded on the literal prefix and an i64 LE index" do
    program_id = Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)
    index = 20_346

    expected, _ = Solana::Transaction.find_pda(
      ["mint_window".b, [index].pack("q<")], program_id
    )
    actual, _ = vault.mint_window_pda(index)
    assert_equal expected, actual

    # u64 and i64 agree on positives, so a negative index is the only case that
    # can tell a wrong pack directive apart from the right one.
    neg_expected, _ = Solana::Transaction.find_pda(
      ["mint_window".b, [-2].pack("q<")], program_id
    )
    neg_actual, _ = vault.mint_window_pda(-2)
    assert_equal neg_expected, neg_actual
    refute_equal expected, neg_actual
  end

  test "the governance PDA is seeded on the bare prefix" do
    program_id = Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)
    expected, _ = Solana::Transaction.find_pda(["governance".b], program_id)
    actual, _ = vault.governance_pda
    assert_equal expected, actual

    # ...and it is NOT the vault PDA, which is the confusion a single-seed
    # derivation invites.
    vault_pda, _ = vault.vault_state_pda
    refute_equal vault_pda, actual
  end

  test "an unreadable governance account falls back to the shipped default" do
    v = vault
    v.stub(:cached_governance, nil) do
      assert_equal Time.at(86_400).to_i.div(Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS),
                   v.mint_window_index(Time.at(86_400))
    end
    assert_equal 86_400, Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS
    assert_equal 250, Solana::Vault::DEFAULT_MINT_WINDOW_CAP
  end

  # ── THE UNATTENDED-THRESHOLD REFUSAL ──────────────────────────────────────
  #
  # Several actions the server used to perform alone now need two or three
  # signatures. Left unguarded, those paths reach the chain and come back as
  # InsufficientSigners (6046) — an error naming neither the action, the
  # threshold, nor the fix, after the fee is already spent.
  test "an unattended action it cannot sign for refuses locally, naming the numbers" do
    v = vault
    Solana::Config.stub(:governance?, true) do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) do
        v.send(:unattended_extra_signer_metas, "settle_contest", required: 3, signers: [])
      end
      assert_match(/settle_contest needs 3 vault signatures/, error.message)
      assert_match(/can produce 1/, error.message)
      assert_match(/extra_signers:/, error.message, "the message must name the remedy")
    end
  end

  test "supplying enough signers satisfies the refusal and lands them as signer metas" do
    v = vault
    kp = Solana::Keypair.from_bytes(Digest::SHA256.digest("switch-test signer"))
    Solana::Config.stub(:governance?, true) do
      metas = v.send(:unattended_extra_signer_metas, "close_contest", required: 2, signers: [kp])
      assert_equal 1, metas.length
      assert_equal kp.public_key_bytes, metas.first[:pubkey]
      assert metas.first[:is_signer], "a remaining account that does not sign is read as CosignerDidNotSign"
      refute metas.first[:is_writable]
    end
  end

  # The control. On the v0.25 branch the same call must be inert — no refusal,
  # no metas — or this guard would break every unattended path the moment it
  # merged, which is the outage the whole design exists to avoid.
  test "the refusal is INERT in the v0.25 shape" do
    v = vault
    Solana::Config.stub(:governance?, false) do
      assert_equal [], v.send(:unattended_extra_signer_metas, "settle_contest", required: 3, signers: [])
    end
  end

  # ── WHAT THE GUARD IS COUNTING ────────────────────────────────────────────
  #
  # The guard used to compute `held = 1 + keypairs.length`, which encodes two
  # assumptions that are both wrong for `settle_contest`: that exactly ONE slot
  # is named, and that a supplied keypair is worth a signature whatever key it
  # carries. `instructions::governance::authorize` asks remaining_accounts for
  # `required - named.len()`, and `VaultState::validate_threshold` counts
  # DISTINCT members and rejects repeats. Both halves are corrected here.

  def spare(tag) = Solana::Keypair.from_bytes(Digest::SHA256.digest("switch-test #{tag}"))

  test "a second NAMED signer counts, so admin + cosigner + one extra reaches three" do
    v = vault
    cosigner = spare("named cosigner")
    Solana::Config.stub(:governance?, true) do
      metas = v.send(:unattended_extra_signer_metas, "settle_contest", required: 3,
                     signers: [spare("third")],
                     named: [Solana::Keypair.admin.public_key_bytes, cosigner.public_key_bytes])
      assert_equal 1, metas.length,
                   "exactly required - named.count metas ride in remaining_accounts"
    end
  end

  # The same call the old accounting REFUSED: it computed 2 for a caller holding
  # three real signatures, so it would have blocked a valid settle the day the
  # signer rotation made one possible.
  test "settle_contest names BOTH of its signer slots" do
    reached = Class.new(StandardError)
    v = vault
    v.define_singleton_method(:build_tx) { |*_args, **_kwargs| raise reached }

    Solana::Config.stub(:governance?, true) do
      # Two named (admin + a distinct cosigner) plus one extra is three — the
      # guard must let this through to the builder.
      assert_raises(reached) do
        v.settle_contest("slug-a", [], cosigner_keypair: spare("settle cosigner"),
                                       extra_signers: [spare("settle third")])
      end

      # ...and one fewer must still be refused, or the fix would just be a
      # disabled guard.
      assert_raises(Solana::Vault::ThresholdUnreachableError) do
        v.settle_contest("slug-a", [], cosigner_keypair: spare("settle cosigner"))
      end
    end
  end

  # `cosigner = cosigner_keypair || admin` is how settle_contest spells "nobody
  # cosigned" — and it puts the ADMIN key in the cosigner slot, which the chain
  # reads as a repeat and rejects with DuplicateSigner. Two keys that are one
  # key are one signature.
  test "the same signer in two slots is one signature, and is refused by name" do
    v = vault
    Solana::Config.stub(:governance?, true) do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) do
        v.settle_contest("slug-a", [], extra_signers: [spare("a"), spare("b")])
      end
      assert_match(/same vault signer more than once/, error.message)
      assert_match(/DuplicateSigner/, error.message, "the message must name the on-chain error it prevents")
    end
  end

  # The form test/services/solana/vault_account_layout_test.rb used to pass to
  # create_season. It satisfied the old array-length count and could never have
  # landed on chain.
  test "a keypair passed twice is refused rather than counted twice" do
    v = vault
    kp = spare("repeated")
    Solana::Config.stub(:governance?, true) do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) do
        v.send(:unattended_extra_signer_metas, "create_season", required: 3, signers: [kp, kp])
      end
      assert_match(/3 keys that are only 2 different ones/, error.message)
    end
  end

  # The control: one named slot is still the default, so the five builders that
  # declare only `admin` need no change and keep their old verdicts exactly.
  test "the default naming is the admin alone, unchanged for every other builder" do
    v = vault
    Solana::Config.stub(:governance?, true) do
      assert_equal 1, v.send(:unattended_extra_signer_metas, "close_contest", required: 2,
                             signers: [spare("one")]).length
      assert_raises(Solana::Vault::ThresholdUnreachableError) do
        v.send(:unattended_extra_signer_metas, "close_contest", required: 2, signers: [])
      end
    end
  end
end
