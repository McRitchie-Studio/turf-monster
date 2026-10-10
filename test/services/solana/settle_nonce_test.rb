require "test_helper"
require "minitest/mock"

# [unit] WHICH SETTLE PATH A CLUSTER TAKES (Solana::SettleNonce), the offline
# CLI cosign (Solana::SettleNonceSigner), and the server submit
# (Solana::SettleNonceSubmission).
class SettleNonceTest < ActiveSupport::TestCase
  include SettleNonceFixture

  def with_config(yaml)
    file = Tempfile.new(["settle_nonce", ".yml"])
    file.write(yaml)
    file.flush
    yield file.path
  ensure
    file&.close!
  end

  def complete(enabled: false)
    <<~YAML
      devnet:
        enabled: #{enabled}
        nonce_account: #{NONCE_ACCOUNT}
        cosigner: #{COSIGNER.to_base58}
      mainnet-beta:
        enabled: false
        nonce_account:
        cosigner:
    YAML
  end

  def current(yaml, network: "devnet", env: {})
    with_config(yaml) { |path| Solana::SettleNonce.current(network: network, env: env, path: path) }
  end

  # ── selection ────────────────────────────────────────────────────────────

  test "the checked-in config leaves both clusters on the blockhash path" do
    assert_nil Solana::SettleNonce.current(network: "mainnet-beta", env: {})
    assert_nil Solana::SettleNonce.current(network: "devnet", env: {})
  end

  test "an enabled entry returns its nonce account and cosigner" do
    settings = current(complete(enabled: true))

    assert_equal NONCE_ACCOUNT, settings.nonce_account
    assert_equal COSIGNER.to_base58, settings.cosigner
    assert_equal({ pubkey: NONCE_ACCOUNT, authority: COSIGNER.to_base58 }, settings.durable_nonce)
  end

  test "the env switch turns a cluster on or off over the file" do
    assert current(complete, env: { "SETTLE_DURABLE_NONCE" => "on" })
    assert_nil current(complete(enabled: true), env: { "SETTLE_DURABLE_NONCE" => "0" })
    assert_raises(Solana::SettleNonce::ConfigError) { current(complete, env: { "SETTLE_DURABLE_NONCE" => "maybe" }) }
  end

  test "an enabled cluster with a blank key raises rather than falling back" do
    error = assert_raises(Solana::SettleNonce::ConfigError) do
      current(complete, network: "mainnet-beta", env: { "SETTLE_DURABLE_NONCE" => "1" })
    end
    assert_match(/nonce_account is blank/, error.message)
  end

  test "an enabled cluster with a malformed key raises" do
    yaml = complete(enabled: true).sub(COSIGNER.to_base58, "not0a0key")

    assert_raises(Solana::SettleNonce::ConfigError) { current(yaml) }
  end

  test "an enabled switch on a cluster the file does not name raises" do
    assert_raises(Solana::SettleNonce::ConfigError) { current(complete, network: "localnet", env: { "SETTLE_DURABLE_NONCE" => "1" }) }
  end

  # ── the build each path takes ────────────────────────────────────────────

  def recording_vault
    calls = []
    vault = Object.new
    vault.define_singleton_method(:build_settle_contest) do |slug, settlements, **kw|
      calls << [slug, settlements, kw]
      { serialized_tx: "WIRE", contest_slug: slug }.merge(kw[:durable_nonce] ? { nonce_value: "NONCE" } : {})
    end
    [vault, calls]
  end

  test "off: the default cosigner and no durable_nonce argument" do
    vault, calls = recording_vault
    result = Solana::SettleNonce.build_settle(vault: vault, slug: "c", settlements: [], default_cosigner: "PHANTOM",
                                              settings: nil)

    assert_equal [["c", [], { cosigner_pubkey: "PHANTOM", extra_cosigners: [] }]], calls
    assert_nil result[:durable_nonce]
  end

  test "on: the CLI cosigner, the nonce, and the metadata a row carries" do
    vault, calls = recording_vault
    settings = current(complete(enabled: true))
    result = Solana::SettleNonce.build_settle(vault: vault, slug: "c", settlements: [], default_cosigner: "PHANTOM",
                                              settings: settings)

    assert_equal COSIGNER.to_base58, calls.first[2][:cosigner_pubkey]
    assert_equal settings.durable_nonce, calls.first[2][:durable_nonce]
    assert_equal({ "account" => NONCE_ACCOUNT, "authority" => COSIGNER.to_base58, "value" => "NONCE" }, result[:durable_nonce])
  end

  # ── offline cosign ───────────────────────────────────────────────────────

  def nonce_wire(governance: false)
    build(governance: governance, nonce: true)[:serialized_tx]
  end

  test "sign fills the CLI keypair's slot with a valid signature over the unchanged message" do
    wire = nonce_wire
    signed = Solana::SettleNonceSigner.sign(wire, COSIGNER)
    parsed = Solana::WireMessage.parse_base64(signed)

    assert_equal Solana::WireMessage.parse_base64(wire).message_bytes, parsed.message_bytes
    assert (0...parsed.num_required_signatures).all? { |i| parsed.signature_valid?(i) }
  end

  test "sign refuses a blockhash settle" do
    blockhash_wire = build[:serialized_tx]

    assert_raises(Solana::SettleNonceSigner::Refused) { Solana::SettleNonceSigner.sign(blockhash_wire, COSIGNER) }
  end

  test "attach takes a detached signature only when it signs this message for that key" do
    wire = nonce_wire
    message = Solana::WireMessage.parse_base64(wire).message_bytes
    good = Solana::Keypair.encode_base58(COSIGNER.sign(message))
    forged = Solana::Keypair.encode_base58(THIRD.sign(message))

    assert_raises(Solana::SettleNonceSigner::Refused) do
      Solana::SettleNonceSigner.attach(wire, pubkey: COSIGNER.to_base58, signature_base58: forged)
    end
    assert_raises(Solana::SettleNonceSigner::Refused) do
      Solana::SettleNonceSigner.attach(wire, pubkey: THIRD.to_base58, signature_base58: Solana::Keypair.encode_base58(THIRD.sign(message)))
    end

    attached = Solana::SettleNonceSigner.attach(wire, pubkey: COSIGNER.to_base58, signature_base58: good)
    assert_equal Solana::SettleNonceSigner.sign(wire, COSIGNER), attached
  end

  test "a Ledger path is refused by name; a keypair file loads only when its halves agree" do
    error = assert_raises(Solana::SettleNonceSigner::Refused) { Solana::SettleNonceSigner.load_keypair("usb://ledger") }
    assert_match(/bin\/settle-nonce attach/, error.message)

    Dir.mktmpdir do |dir|
      good = File.join(dir, "good.json")
      File.write(good, COSIGNER.to_bytes.bytes.to_json)
      assert_equal COSIGNER.to_base58, Solana::SettleNonceSigner.load_keypair(good).to_base58

      bad = File.join(dir, "bad.json")
      File.write(bad, (COSIGNER.to_bytes.bytes.first(32) + THIRD.public_key_bytes.bytes).to_json)
      assert_raises(Solana::SettleNonceSigner::Refused) { Solana::SettleNonceSigner.load_keypair(bad) }
    end
  end

  # ── server submit ────────────────────────────────────────────────────────

  def nonce_row(wire)
    contest = Contest.create!(name: "Nonce settle #{SecureRandom.hex(3)}", slate: slates(:one), rank: 9000 + rand(900),
                              contest_type: "standard", starts_at: 1.hour.ago, user: users(:alex), status: "open",
                              max_entries: 29)
    PendingTransaction.create!(tx_type: "settle_contest", serialized_tx: wire, target: contest,
                               initiator_address: Solana::Keypair.admin.to_base58,
                               metadata: { settlements: [], durable_nonce: { account: NONCE_ACCOUNT } }.to_json)
  end

  def broadcasting_vault(sent)
    vault = Object.new
    vault.define_singleton_method(:simulate_and_broadcast) { |w| sent << w; "sig" }
    vault
  end

  test "submit broadcasts a fully signed wire for the stored message and claims the row with its signature" do
    wire = nonce_wire
    row = nonce_row(wire)
    signed = Solana::SettleNonceSigner.sign(wire, COSIGNER)
    sent = []

    signature = Solana::SettleNonceSubmission.new(row, vault: broadcasting_vault(sent)).submit!(signed)

    assert_equal [signed], sent
    assert_equal Solana::WireMessage.parse_base64(signed).signature, signature
    assert_equal ["submitted", signature], [row.reload.status, row.tx_signature]
  end

  test "submit refuses a different message, an empty slot, and a blockhash row, sending nothing" do
    wire = nonce_wire
    sent = []
    other = Solana::SettleNonceSigner.sign(nonce_wire(governance: true), COSIGNER)

    row = nonce_row(wire)
    submission = Solana::SettleNonceSubmission.new(row, vault: broadcasting_vault(sent))
    assert_raises(Solana::SettleNonceSubmission::Refused) { submission.submit!(other) }
    assert_raises(Solana::SettleNonceSubmission::Refused) { submission.submit!(wire) }

    row.update!(metadata: { settlements: [] }.to_json)
    assert_raises(Solana::SettleNonceSubmission::Refused) { submission.submit!(Solana::SettleNonceSigner.sign(wire, COSIGNER)) }

    assert_empty sent
    assert_equal "pending", row.reload.status
  end

  test "a preflight refusal gives the claim back" do
    row = nonce_row(nonce_wire)
    vault = Object.new
    vault.define_singleton_method(:simulate_and_broadcast) { |_w| raise Solana::Cosign::PreflightRejected, "BlockhashNotFound" }
    vault.define_singleton_method(:read_contest) { |*_a, **_k| { status: "Locked" } }

    assert_raises(Solana::Cosign::PreflightRejected) do
      Solana::SettleNonceSubmission.new(row, vault: vault).submit!(Solana::SettleNonceSigner.sign(row.serialized_tx, COSIGNER))
    end
    assert_equal ["pending", nil], [row.reload.status, row.tx_signature]
  end
end
