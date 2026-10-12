require "test_helper"

# [unit] Solana::SquadsProposals — Squads V4 proposal and vault-transaction
# decoding against LIVE account bytes (mainnet #5, #7, #8 and devnet #17, read
# 2026-10-12 and cross-checked with @sqds/multisig's own decoders), the
# upgrade buffer-hash check, and the approve instruction.
class Solana::SquadsProposalsTest < ActiveSupport::TestCase
  MULTISIG = "4H3fP3otjMtupk1DQDjKXYY1dWjT6LNM4H4ZWZ1XcKSX".freeze
  VAULT = "Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm".freeze
  PROGRAM = "DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM".freeze
  BUFFER = "CToebfDCmJcaVXfoUWWK2cJDHuzTtuxMmoxC5JavcEAk".freeze
  ALEX = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  SYSTEM_SEAT = "7auwTLSvNniSUeAgL6v9RStMXJhWrrUhSJgwFWLpcqC".freeze
  GOV = "4bKNSqkrKeggSyrds16Ak7rcB4ibvGJ4ZLsKjvQgC3Vk".freeze

  def fixture(name) = Base64.decode64(file_fixture("squads/#{name}.b64").read)

  # Serves raw accounts by address; anything else reads as absent.
  class AccountsClient
    attr_reader :reads

    def initialize(accounts, owner: {})
      @accounts = accounts
      @owner = owner
      @reads = []
    end

    def get_account_info(address, **)
      @reads << address
      raw = @accounts[address]
      return { "value" => nil } unless raw

      { "value" => { "data" => [Base64.strict_encode64(raw), "base64"],
                     "owner" => @owner.fetch(address, Solana::Squads::PROGRAM_ID) } }
    end

    def get_latest_blockhash(**) = "GfVcyD4kkTrj4bKc7WA9sZCin9JDbdT4Zkd3EittNR1W"
  end

  # A Proposal account in the V4 layout, for states the live fixtures do not hold.
  def proposal_bytes(index, status: 1, approved: [])
    keys = ->(list) { [list.length].pack("L<") + list.map { |k| Solana::Keypair.decode_base58(k) }.join }
    Solana::SquadsProposals::PROPOSAL_DISC + Solana::Keypair.decode_base58(MULTISIG) + [index].pack("Q<") +
      [status].pack("C") + [1_760_000_000].pack("q<") + "\xFF".b + keys.(approved) + keys.([]) + keys.([])
  end

  def buffer_bytes(elf, authority: VAULT)
    [1].pack("L<") + "\x01".b + Solana::Keypair.decode_base58(authority) + elf + ("\x00" * 64).b
  end

  def service(accounts)
    Solana::SquadsProposals.new(network: "mainnet-beta", client: AccountsClient.new(accounts),
                                multisig: MULTISIG, program_id: PROGRAM)
  end

  # ── decoders, against live bytes ──────────────────────────────────────────

  test "the live mainnet multisig decodes its transaction and stale indices" do
    ms = Solana::Squads.decode(fixture("mainnet_multisig"))
    assert_equal 3, ms[:threshold]
    assert_equal 8, ms[:transaction_index]
    assert_equal 6, ms[:stale_transaction_index]
  end

  test "the executed v0.26 upgrade proposal decodes status and approvals" do
    p = Solana::SquadsProposals.decode_proposal(fixture("mainnet_proposal_8"))
    assert_equal "executed", p[:status]
    assert_equal 8, p[:transaction_index]
    assert_equal [SYSTEM_SEAT, GOV, ALEX], p[:approved]
  end

  test "an active devnet proposal decodes with its one approval" do
    p = Solana::SquadsProposals.decode_proposal(fixture("devnet_proposal_17_active"))
    assert_equal "active", p[:status]
    assert_equal ["BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo"], p[:approved]
  end

  test "the v0.26 upgrade vault transaction reads as an upgrade of turf-vault by the vault" do
    tx = Solana::SquadsProposals.decode_vault_transaction(fixture("mainnet_vault_tx_8_upgrade"))
    assert_equal [1, 1, 3], tx[:header]
    s = Solana::SquadsProposals.summarize(tx)
    assert_equal "upgrade", s[:kind]
    assert_equal PROGRAM, s[:program]
    assert_equal BUFFER, s[:buffer]
    assert_equal VAULT, s[:authority]
    assert_equal VAULT, s[:spill]
  end

  test "a SOL transfer reads as one; a transfer through lookup tables says it cannot be read" do
    sol = Solana::SquadsProposals.summarize(
      Solana::SquadsProposals.decode_vault_transaction(fixture("mainnet_vault_tx_7_sol_transfer")))
    assert_equal "sol_transfer", sol[:kind]
    assert_equal VAULT, sol[:from]
    assert_equal 0x01718c7e00, sol[:lamports]

    # #5 (a USDC transfer) names its mint and token programs through an address
    # lookup table, so its accounts are not in the message. The honest answer is
    # "unreadable here", never a guess at indices past the key table.
    tx = Solana::SquadsProposals.decode_vault_transaction(fixture("mainnet_vault_tx_5_token_transfer"))
    assert_equal 1, tx[:address_table_lookups].length
    assert_equal "unreadable", Solana::SquadsProposals.summarize(tx)[:kind]
  end

  test "a truncated account is a DecodeError, not a garbage read" do
    raw = fixture("mainnet_vault_tx_8_upgrade")
    assert_raises(Solana::SquadsProposals::DecodeError) do
      Solana::SquadsProposals.decode_vault_transaction(raw.byteslice(0, 120))
    end
  end

  test "the buffer hash trims trailing zeros, as solana-verify does" do
    elf = "\x7FELF-program-bytes".b
    assert_equal Digest::SHA256.hexdigest(elf), Solana::SquadsProposals.buffer_hash(buffer_bytes(elf))
  end

  # ── the open list and the verdicts ────────────────────────────────────────

  def open_upgrade_accounts(svc, elf:, approved: [SYSTEM_SEAT, GOV], buffer_authority: VAULT)
    {
      MULTISIG => fixture("mainnet_multisig"),
      svc.proposal_pda(8) => proposal_bytes(8, approved: approved),
      svc.transaction_pda(8) => fixture("mainnet_vault_tx_8_upgrade"),
      BUFFER => buffer_bytes(elf, authority: buffer_authority)
    }
  end

  def open_rows(elf:, builds:, connected: ALEX, **opts)
    probe = service({})
    svc = service(open_upgrade_accounts(probe, elf: elf, **opts))
    Solana::SquadsProposals.stub(:builds, builds) { svc.open_proposals(connected: connected) }
  end

  test "an open upgrade whose buffer matches a verified build is approvable by Alex" do
    elf = "verified-build".b
    rows = open_rows(elf: elf, builds: [{ "version" => "v0.27.0", "sha256" => Digest::SHA256.hexdigest(elf) }])

    assert_equal 1, rows.length
    row = rows.first
    assert_equal 8, row[:index]
    assert_equal "upgrade", row[:summary][:kind]
    assert row[:verification][:ok]
    assert_equal "v0.27.0", row[:verification][:build_version]
    assert_equal 1, row[:approvals_needed]
    assert row[:connected_is_voter]
    assert row[:can_approve]
    assert_equal "https://app.squads.so/squads/#{VAULT}/transactions", row[:squads_url]
  end

  test "an upgrade whose buffer matches no verified build is NOT approvable" do
    row = open_rows(elf: "tampered".b, builds: [{ "version" => "v0.27.0", "sha256" => "0" * 64 }]).first
    refute row[:verification][:ok]
    refute row[:can_approve]
    assert_match(/matches no verified build/, row[:approve_blocked])
  end

  test "a buffer whose authority is not the vault is NOT approvable" do
    elf = "verified-build".b
    row = open_rows(elf: elf, builds: [{ "version" => "v0.27.0", "sha256" => Digest::SHA256.hexdigest(elf) }],
                    buffer_authority: ALEX).first
    refute row[:can_approve]
    assert_match(/buffer's authority/, row[:approve_blocked])
  end

  test "a connected account that is not a voter, or already approved, cannot approve" do
    elf = "verified-build".b
    builds = [{ "version" => "v0.27.0", "sha256" => Digest::SHA256.hexdigest(elf) }]
    outsider = open_rows(elf: elf, builds: builds, connected: "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo").first
    assert_match(/not a voting member/, outsider[:approve_blocked])

    voted = open_rows(elf: elf, builds: builds, approved: [SYSTEM_SEAT, ALEX]).first
    assert_match(/already approved/, voted[:approve_blocked])
  end

  test "executed proposals are not listed" do
    probe = service({})
    svc = service(MULTISIG => fixture("mainnet_multisig"), probe.proposal_pda(8) => fixture("mainnet_proposal_8"))
    assert_equal [], svc.open_proposals(connected: ALEX)
  end

  # ── the approve instruction ───────────────────────────────────────────────

  test "build_approve returns an unsigned vote for the connected member, who pays its fee" do
    elf = "verified-build".b
    probe = service({})
    svc = service(open_upgrade_accounts(probe, elf: elf))
    built = Solana::SquadsProposals.stub(:builds, [{ "version" => "v", "sha256" => Digest::SHA256.hexdigest(elf) }]) do
      svc.build_approve(index: 8, member: ALEX)
    end

    raw = Base64.decode64(built[:serialized_tx])
    assert_equal 1, raw.getbyte(0), "one signature slot: the member's"
    assert_equal ("\x00" * 64).b, raw.byteslice(1, 64), "nothing pre-signed"
    message = raw.byteslice(65..)
    fee_payer = Solana::Keypair.encode_base58(message.byteslice(4, 32))
    assert_equal ALEX, fee_payer
    assert_includes message, Solana::SquadsProposals::APPROVE_DISC + "\x00".b
    assert_includes message, Solana::Keypair.decode_base58(probe.proposal_pda(8))
  end

  test "build_approve refuses what the page refuses to offer" do
    probe = service({})
    svc = service(open_upgrade_accounts(probe, elf: "tampered".b))
    error = assert_raises(Solana::SquadsProposals::Refusal) do
      Solana::SquadsProposals.stub(:builds, []) { svc.build_approve(index: 8, member: ALEX) }
    end
    assert_equal "not_approvable", error.code
  end
end
