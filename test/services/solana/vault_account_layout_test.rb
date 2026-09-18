require "test_helper"

# THE KEYSTONE GUARD for the v0.25 <-> v0.26 account-shape switch.
#
# Every turf-vault instruction is a POSITIONAL account list. Anchor reads slot N
# as the Nth field of the `#[derive(Accounts)]` struct, so an account inserted,
# omitted, or moved by one does not fail politely — it makes the program read
# some other account as the one it wanted, and the error it returns names the
# wrong thing. The repo had NO test asserting a full ordered account list for
# any builder before this file; the only order pin anywhere was a single
# hard-coded index used by the cosign guard.
#
# That is exactly the blind spot v0.26 walks into. It adds `governance` to
# EVERY vault-authorized instruction, `treasury` to close_contest, `mint_window`
# to mint_entry_token, `invitee_user_account` to grant_seeds, and
# `username_record` to the two username paths. This app now carries BOTH shapes
# and picks between them at boot (`Solana::Config.governance?`), so there are two
# correct answers per builder and no way to eyeball which one shipped.
#
# So the assertions here are made against the COMMITTED IDLs rather than against
# a list retyped from the program. `config/turf_vault.idl.json` (v0.25) and
# `config/turf_vault.v026.idl.json` (v0.26) are the artifacts the boot guard
# hashes, so a test that agrees with them agrees with the thing production
# verifies. A hand-written expectation would only prove this file and vault.rb
# were written by the same person on the same afternoon.
class Solana::VaultAccountLayoutTest < ActiveSupport::TestCase
  V025_IDL = JSON.parse(File.read(Rails.root.join("config", "turf_vault.idl.json"))).freeze
  V026_IDL = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json"))).freeze

  # A recording stand-in for Solana::Transaction. Captures the turf-vault
  # instruction's account metas without building, signing, or serializing a
  # wire — the layout is the whole subject, and a wire decode would only add a
  # second thing that could be wrong.
  class RecordingTx
    attr_reader :captured, :signers

    def initialize
      @captured = []
      @signers = []
    end

    def add_instruction(program_id: nil, accounts: nil, data: nil, **_rest)
      @captured << { program_id: program_id, accounts: accounts, data: data }
      self
    end

    def add_signer(kp)
      @signers << kp
      self
    end

    def serialize_base64 = "RecordedTxBase64"
    def serialize_partial_base64(**_kwargs) = "RecordedPartialBase64"
  end

  # A Vault whose tx assembly is replaced by the recorder above. Both partial
  # builders funnel into the same record so one reader serves every builder.
  class CapturingVault < Solana::Vault
    attr_reader :recorder

    def initialize(**kwargs)
      super
      @recorder = RecordingTx.new
    end

    def build_tx(_signer = nil, durable_nonce: nil)
      @recorder
    end

    def build_partial_signed(accounts:, data:, additional_signers:, durable_nonce: nil)
      @recorder.add_instruction(program_id: @program_id, accounts: accounts, data: data)
      @additional_signers = additional_signers
      "RecordedPartialBase64"
    end

    # THE PHANTOM-FIRST BUILDER IS `Cosign::Builder`-BACKED NOW, so this stand-in
    # carries its shape rather than the old one: ONE `cosigner:` instead of an
    # ordered `additional_signers` list (the fee payer is account 0 by
    # construction in the gem), no `durable_nonce:` (a Phantom-signed wire can
    # never be nonce-anchored), and a `Cosign::Prepared` back instead of a base64
    # String — every caller reads `.wire_base64` and `.last_valid_block_height`
    # off it. A stub returning the old String makes each caller die on
    # NoMethodError, which is how this file broke; the layout it certifies is
    # unchanged either way, because the accounts are recorded before the wire
    # would be built.
    def build_partial_unsigned(accounts:, data:, cosigner:)
      @recorder.add_instruction(program_id: @program_id, accounts: accounts, data: data)
      @cosigner = cosigner
      Solana::Cosign::Prepared.new(wire_base64: "RecordedPartialBase64",
                                   last_valid_block_height: 1_000_000)
    end

    attr_reader :additional_signers, :cosigner
  end

  # An RPC that answers only what a builder needs to finish assembling, and
  # answers it deterministically.
  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |commitment: "finalized"| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
    CosignFakeClient.teach(client)
    client.define_singleton_method(:send_and_confirm) { |_wire| "RecordedSignature" }
    client.define_singleton_method(:get_account_info) { |_pubkey, **_kw| nil }
    client
  end

  def vault
    CapturingVault.new(client: fake_client)
  end

  # Run `blk` with the app resolved to one shape or the other. `governance?` is
  # the single seam every builder reads, which is what makes a two-shape app
  # testable at all — the alternative would be re-booting under a different ENV.
  def with_shape(governance)
    Solana::Config.stub(:governance?, governance) { yield }
  end

  def idl_for(governance)
    governance ? V026_IDL : V025_IDL
  end

  def idl_accounts(governance, ix_name)
    ix = idl_for(governance).fetch("instructions").find { |i| i["name"] == ix_name }
    refute_nil ix, "#{ix_name} is absent from the #{governance ? 'v0.26' : 'v0.25'} IDL"
    ix.fetch("accounts")
  end

  # The one turf-vault instruction in the recorder (builders that prepend a
  # ComputeBudget ix put it on the same recorder, so select by program id).
  # `create_contest_instruction` is a pure SPEC builder — it assembles the list
  # and hands it back instead of adding it to a transaction — so its return
  # value is accepted directly rather than special-cased into the recorder.
  def captured_accounts(v, returned = nil)
    return returned[:accounts] if returned.is_a?(Hash) && returned[:accounts].is_a?(Array)

    ix = v.recorder.captured.find { |c| c[:program_id] == v.instance_variable_get(:@program_id) }
    refute_nil ix, "no turf-vault instruction was recorded"
    ix[:accounts]
  end

  # A deterministic throwaway vault signer, for the builders whose v0.26
  # threshold the server cannot reach alone. It never signs anything here — the
  # layout is the subject — it only lets the builder past its own refusal.
  def spare_signer
    @spare_signer ||= Solana::Keypair.from_bytes(Digest::SHA256.digest("layout-test spare cosigner"))
  end

  # A SECOND, DIFFERENT spare, for the builders that need two.
  #
  # `[spare_signer, spare_signer]` used to stand in for two — and the Rails
  # guard accepted it, because it counted the ARRAY rather than the distinct
  # pubkeys. turf-vault's `validate_threshold` rejects any repeated key outright
  # (`DuplicateSigner`): the same keypair signing twice is one signature. So
  # that list normalized a shape the chain refuses, and the layout it certified
  # could never have landed.
  def spare_signer2
    @spare_signer2 ||= Solana::Keypair.from_bytes(Digest::SHA256.digest("layout-test spare cosigner 2"))
  end

  WALLET = "HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH".freeze
  WALLET2 = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze
  COSIGNER = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  COSIGNER2 = "GDDMwNyyx8uB6zrqwBFHjLLG3TBYk2F8Az4yrQC5RzMp".freeze

  # Every builder this app owns, with the turf-vault instruction it emits and a
  # thunk that drives it. Kept in ONE table so a new builder cannot be added
  # without either appearing here or failing the completeness test at the end.
  def builder_cases(v)
    {
      "pause" => -> { v.build_pause_vault(cosigner_pubkey: COSIGNER, reason: "test") },
      "unpause" => -> { v.build_unpause_vault(cosigner_pubkey: COSIGNER, extra_cosigners: Solana::Config.governance? ? [COSIGNER2] : []) },
      "register_currency" => -> { v.build_register_currency(cosigner_pubkey: COSIGNER, mint: Solana::Config::USDC_MINT) },
      "deactivate_currency" => -> { v.build_deactivate_currency(cosigner_pubkey: COSIGNER, currency_idx: 1) },
      "create_user_account" => -> { v.create_user_account(WALLET, username: "tester") },
      "set_username" => -> { v.build_set_username(WALLET, "tester") },
      "create_contest" => -> { v.create_contest_instruction(WALLET, "slug-a", entry_fee_by_currency: [1], max_entries: 10, payout_amounts: [1], prize_pool: 1, lock_timestamp: 0, season_id: 1) },
      "set_contest_lock_time" => -> { v.build_set_contest_lock_time("slug-a", 123, admin_pubkey: COSIGNER) },
      "set_contest_conclusion_time" => -> { v.build_set_contest_conclusion_time("slug-a", 123, admin_pubkey: COSIGNER) },
      "cancel_contest" => -> { v.build_cancel_contest("slug-a", creator_pubkey: WALLET, cosigner_pubkey: COSIGNER) },
      "settle_contest" => -> { v.build_settle_contest("slug-a", [], cosigner_pubkey: COSIGNER) },
      "close_contest" => -> { v.close_contest("slug-a", extra_signers: Solana::Config.governance? ? [spare_signer] : []) },
      "create_season" => -> { v.create_season(season_id: 1, name: "S", schedule: [1, 1, 1, 1, 1], extra_signers: Solana::Config.governance? ? [spare_signer, spare_signer2] : []) },
      "sweep_operator_revenue" => -> { v.build_sweep_operator_revenue(cosigner_pubkey: COSIGNER, currency_mint: Solana::Config::USDC_MINT, treasury_ata_pubkey: WALLET2) },
      "enter_contest" => -> { v.build_enter_contest(WALLET, "slug-a", 0, currency_idx: 0, season_id: 1) },
      "enter_contest_with_token" => -> { v.build_enter_contest_with_token(WALLET, "slug-a", 0, WALLET2, season_id: 1) },
      "mint_entry_token" => -> { v.mint_entry_token(wallet_address: WALLET, source: :operator, source_ref: "ref-1") },
      "grant_seeds" => -> { v.grant_seeds(wallet_address: WALLET, amount: 5, kind: :newsletter) }
    }
  end

  # ── THE MAIN EVENT ────────────────────────────────────────────────────────
  #
  # For every builder, in BOTH shapes: the account list it produces must have
  # the same length, the same signer flags and the same writable flags as the
  # IDL for that shape declares. Length alone would miss a swap; the flags are
  # what catch an account inserted at the wrong index with a plausible count.
  [false, true].each do |governance|
    label = governance ? "v0.26" : "v0.25"

    test "every builder's account list matches the #{label} IDL" do
      with_shape(governance) do
        checked = 0
        program_id = vault.instance_variable_get(:@program_id)
        builder_cases(vault).each do |ix_name, _thunk|
          v = vault
          returned = builder_cases(v).fetch(ix_name).call
          actual = captured_accounts(v, returned)
          expected = idl_accounts(governance, ix_name)

          assert_operator actual.length, :>=, expected.length,
                          "#{ix_name} (#{label}): expected at least #{expected.length} accounts " \
                          "(#{expected.map { |a| a['name'] }.join(', ')}), built #{actual.length}"

          # Anything past the IDL's named list is a LEADING remaining account —
          # the shape `instructions::governance::authorize` reads extra vault
          # signatures from. Every one of them must be a signer; a non-signer
          # there is junk the program would read as a cosigner that did not sign.
          actual[expected.length..].to_a.each_with_index do |meta, i|
            assert meta[:is_signer],
                   "#{ix_name} (#{label}): surplus account #{expected.length + i} is not a signer"
          end

          expected.each_with_index do |spec, idx|
            # ANCHOR'S OWN RULE for an optional account, mirrored rather than
            # invented: an absent one is encoded as the PROGRAM ID with BOTH
            # flags forced false, whatever the IDL says the slot carries when it
            # is present. From @coral-xyz/anchor, program/namespace/instruction.js:
            #   isOptional = acc.optional && pubkey.equals(programId)
            #   isWritable = Boolean(acc.writable && !isOptional)
            #   isSigner   = Boolean(acc.signer   && !isOptional)
            # Asserting the IDL's flags unconditionally would fail every
            # correctly-absent optional — `cosigner` on the two time setters, and
            # `previous_username_record` on a non-rename.
            absent = spec["optional"] && actual[idx][:pubkey] == program_id
            assert_equal(!!spec["signer"] && !absent, !!actual[idx][:is_signer],
                         "#{ix_name} (#{label}) slot #{idx} (#{spec['name']}): signer flag")
            assert_equal(!!spec["writable"] && !absent, !!actual[idx][:is_writable],
                         "#{ix_name} (#{label}) slot #{idx} (#{spec['name']}): writable flag")
          end
          checked += 1
        end
        assert_operator checked, :>=, 18, "the builder table shrank — a builder lost its layout guard"
      end
    end
  end

  # ── THE GOVERNANCE ACCOUNT LANDS WHERE THE IDL PUTS IT ────────────────────
  #
  # The flag comparison above would pass if `governance` and some other
  # non-signer non-writable account swapped places, because their flags are
  # identical. This pins the PDA itself, at the index the IDL names.
  test "the governance PDA sits at the IDL's governance index, in every instruction that declares one" do
    with_shape(true) do
      expected_pda, _ = vault.governance_pda
      checked = 0

      builder_cases(vault).each do |ix_name, _|
        spec = idl_accounts(true, ix_name)
        idx = spec.index { |a| a["name"] == "governance" }
        next if idx.nil?

        v = vault
        returned = builder_cases(v).fetch(ix_name).call
        assert_equal expected_pda, captured_accounts(v, returned)[idx][:pubkey],
                     "#{ix_name}: slot #{idx} should be the [b\"governance\"] PDA"
        checked += 1
      end

      assert_operator checked, :>=, 14,
                      "fewer instructions carried a governance account than the IDL declares"
    end
  end

  # The v0.25 branch has to be byte-identical to what shipped, or this PR is an
  # outage rather than a preparation. No builder may emit the governance PDA
  # while the app is resolved to the old program.
  test "no builder emits the governance PDA in the v0.25 shape" do
    with_shape(false) do
      gov_pda, _ = vault.governance_pda

      builder_cases(vault).each_key do |ix_name|
        v = vault
        returned = builder_cases(v).fetch(ix_name).call
        pubkeys = captured_accounts(v, returned).map { |m| m[:pubkey] }
        refute_includes pubkeys, gov_pda,
                        "#{ix_name} passed the governance account to the v0.25 program, which would reject it"
      end
    end
  end

  # ── THE NEW NAMED ACCOUNTS ────────────────────────────────────────────────

  test "close_contest pays reclaimed rent to the pinned treasury, not the caller" do
    with_shape(true) do
      v = vault
      Solana::Vault.stub(:cached_vault_state, { treasury_authority: WALLET2 }) do
        v.close_contest("slug-a", extra_signers: [spare_signer])
      end
      idx = idl_accounts(true, "close_contest").index { |a| a["name"] == "treasury" }
      meta = captured_accounts(v)[idx]

      assert_equal Solana::Keypair.decode_base58(WALLET2), meta[:pubkey]
      assert meta[:is_writable], "the rent destination must be writable"
      refute_equal Solana::Keypair.admin.public_key_bytes, meta[:pubkey],
                   "the admin is the CALLER; paying rent there is the incentive v0.26 removed"
    end
  end

  test "mint_entry_token passes the current mint window and its index argument" do
    with_shape(true) do
      v = vault
      frozen = Time.utc(2026, 9, 15, 12, 0, 0)
      expected_index = frozen.to_i.div(Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS)

      travel_to(frozen) do
        v.stub(:cached_governance, { mint_window_seconds: Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS, mint_window_cap: 250 }) do
          v.mint_entry_token(wallet_address: WALLET, source: :operator, source_ref: "ref-window")
        end
      end

      idx = idl_accounts(true, "mint_entry_token").index { |a| a["name"] == "mint_window" }
      expected_pda, _ = v.mint_window_pda(expected_index)
      assert_equal expected_pda, captured_accounts(v)[idx][:pubkey]

      # ...and the index must ALSO ride as the trailing i64 argument, because the
      # handler pins the seed against its own clock and rejects a disagreement.
      data = v.recorder.captured.last[:data]
      assert_equal [expected_index].pack("q<"), data[-8, 8],
                   "window_index must be the last 8 bytes of the instruction data"
    end
  end

  test "grant_seeds names the invitee's own account for invites and omits it otherwise" do
    with_shape(true) do
      idx = idl_accounts(true, "grant_seeds").index { |a| a["name"] == "invitee_user_account" }

      invite = vault
      invite.grant_seeds(wallet_address: WALLET, amount: 5, kind: :invite, invitee: WALLET2)
      expected_pda, _ = invite.user_account_pda(WALLET2)
      assert_equal expected_pda, captured_accounts(invite)[idx][:pubkey],
                   "an :invite grant must bind the guard to a REAL invitee account"

      # Every other kind must pass the ABSENT-optional encoding. Passing a real
      # account there is refused by the program (InvalidSeedGrantInvitee), not
      # ignored, so "omit it" has to mean the program id and nothing else.
      plain = vault
      plain.grant_seeds(wallet_address: WALLET, amount: 5, kind: :newsletter)
      assert_equal plain.instance_variable_get(:@program_id), captured_accounts(plain)[idx][:pubkey],
                   "Anchor encodes an absent optional account as the program id"
    end
  end

  # ── THE COSIGN GUARD'S SLOTS MOVE WITH THE SHAPE ──────────────────────────
  #
  # This is the one that is a security bug rather than a correctness bug. The
  # C1 blind-cosign guard reads a FIXED index to prove a Phantom-signed wire
  # binds the session's wallet to the entry PDA we derived. `governance` is
  # inserted ahead of that slot, so an index left at its v0.25 value would send
  # the guard to look at `contest` — and report a pass.
  test "the cosign guard's entry-PDA slot tracks the shape and matches the IDL" do
    { false => V025_IDL, true => V026_IDL }.each do |governance, idl|
      with_shape(governance) do
        %w[enter_contest enter_contest_with_token].each do |ix_name|
          accounts = idl.fetch("instructions").find { |i| i["name"] == ix_name }.fetch("accounts")
          assert_equal accounts.index { |a| a["name"] == "contest_entry" },
                       Solana::Vault.enter_contest_entry_pda_position,
                       "#{ix_name}: entry-PDA slot disagrees with the #{governance ? 'v0.26' : 'v0.25'} IDL"
        end

        token_accounts = idl.fetch("instructions").find { |i| i["name"] == "enter_contest_with_token" }.fetch("accounts")
        assert_equal token_accounts.index { |a| a["name"] == "entry_token" },
                     Solana::Vault.enter_contest_with_token_token_pda_position,
                     "entry-token slot disagrees with the #{governance ? 'v0.26' : 'v0.25'} IDL"
      end
    end
  end

  # A control: the two positions must actually DIFFER between the shapes. Without
  # this, a pair of accessors that ignored the switch and returned the v0.25
  # numbers would satisfy the assertion above on the v0.25 pass and be caught
  # only by the v0.26 pass — and if both IDLs ever agreed by accident, not at all.
  test "the guard slots really do shift between the two shapes" do
    old = with_shape(false) { Solana::Vault.enter_contest_entry_pda_position }
    new = with_shape(true) { Solana::Vault.enter_contest_entry_pda_position }
    assert_equal old + 1, new, "governance is inserted ahead of contest_entry, so the slot must move by exactly one"
  end

  # ── COMPLETENESS ──────────────────────────────────────────────────────────
  #
  # Every instruction the v0.26 IDL says takes a governance account must have a
  # builder in the table above, OR be listed here as deliberately un-built. A
  # missing builder is the failure mode that hurts most: it ships looking fine
  # and breaks the first time an operator reaches for it.
  NOT_BUILT_BY_RAILS = %w[
    initialize init_governance set_action_threshold set_mint_window_policy
    update_signers burn_entry_token overwrite_username reserve_username
    release_reserved_username backfill_username_record
  ].freeze

  test "every governance-bearing instruction is either built here or explicitly unbuilt" do
    declared = V026_IDL.fetch("instructions")
                       .select { |i| i.fetch("accounts").any? { |a| a["name"] == "governance" } }
                       .map { |i| i["name"] }
    built = builder_cases(vault).keys

    unaccounted = declared - built - NOT_BUILT_BY_RAILS
    assert_empty unaccounted,
                 "these v0.26 instructions take a governance account but nothing builds or excuses them: #{unaccounted.join(', ')}"

    stale = NOT_BUILT_BY_RAILS & built
    assert_empty stale, "listed as unbuilt but a builder exists: #{stale.join(', ')}"
  end

  # The two instructions v0.26 DELETED. They are gone from the program, not
  # deprecated, so a caller would fail with an unknown discriminator. Confirms
  # the brief's claim rather than trusting it.
  test "the deleted admin username instructions are absent from the v0.26 IDL and uncalled" do
    v026_names = V026_IDL.fetch("instructions").map { |i| i["name"] }
    %w[admin_create_user_account admin_set_username].each do |gone|
      assert_includes V025_IDL.fetch("instructions").map { |i| i["name"] }, gone
      refute_includes v026_names, gone

      ruby = Dir[Rails.root.join("{app,lib,bin}/**/*.rb")]
             .select { |f| File.read(f).include?("anchor_discriminator(\"#{gone}\")") }
      assert_empty ruby, "#{gone} is deleted from the program but still built by: #{ruby.join(', ')}"
    end
  end
end
