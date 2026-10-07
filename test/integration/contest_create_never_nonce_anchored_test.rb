# frozen_string_literal: true

require "test_helper"

# NO PHANTOM-SIGNED CONTEST CREATE IS ANCHORED ON THE DURABLE NONCE
# (retire-nonce-contest-prepare).
#
# ContestsController#prepare_onchain_contest built a contest create the admin
# signed and the creator's wallet co-signed, anchored on the production durable
# nonce (SOLANA_DURABLE_NONCE_PUBKEY). No view or JS called it, so only a
# hand-made POST reached it, and a nonce-anchored transaction stays landable
# until the nonce advances: a create signed today could land, and move the
# creator's prize pool, at any later time. The route is retired, and the
# builder's co-signed branch no longer reads the nonce, so a future caller
# cannot bring it back by accident.
class ContestCreateNeverNonceAnchoredTest < ActionDispatch::IntegrationTest
  SYSTEM_PROGRAM_B58 = "11111111111111111111111111111111"
  ADVANCE_NONCE_ACCOUNT = [4].pack("L<").freeze # SystemInstruction::AdvanceNonceAccount
  # A real entrant wallet, distinct from the admin key (see vault_durable_nonce_test.rb).
  WALLET = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
  SLUG   = "never-nonce-create"
  CREATE_PARAMS = {
    entry_fee_by_currency: [19_000_000], max_entries: 29,
    payout_amounts: [300_000_000, 50_000_000], prize_pool: 350_000_000,
    season_id: 1, lock_timestamp: 0
  }.freeze

  # ── THE ROUTE ─────────────────────────────────────────────────────────────

  test "POST prepare_onchain_contest is not routed" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/contests/#{contests(:one).slug}/prepare_onchain_contest", method: :post)
    end
    assert_not ContestsController.action_methods.include?("prepare_onchain_contest"),
               "the action is gone, not merely unrouted"
  end

  test "an admin's hand-made POST to prepare_onchain_contest answers 404" do
    log_in_as(users(:alex))

    post "/contests/#{contests(:one).slug}/prepare_onchain_contest"

    assert_response :not_found
  end

  # ── THE BUILDER ───────────────────────────────────────────────────────────

  # Both branches of the one contest-create builder. Each leaves the creator's
  # signature slot for the wallet, so each is a Phantom-signed transaction.
  [true, false].each do |admin_signs|
    test "build_create_contest(admin_signs: #{admin_signs}) carries no nonce instruction with the nonce env set" do
      nonce_value = Solana::Keypair.generate.to_base58
      client = nonce_client(nonce_value)
      vault  = Solana::Vault.new(client: client)

      built = with_durable_nonce_env(Solana::Keypair.generate.to_base58) do
        vault.build_create_contest(WALLET, SLUG, **CREATE_PARAMS, admin_signs: admin_signs)
      end

      ixs = decode_instructions(built[:serialized_tx])
      assert ixs.any?, "the decoder read the wire"
      advances = ixs.select { |ix| ix[:program_id_b58] == SYSTEM_PROGRAM_B58 && ix[:data].start_with?(ADVANCE_NONCE_ACCOUNT) }
      assert_empty advances, "a Phantom-signed contest create must not carry advanceNonceAccount"
      refute Base64.decode64(built[:serialized_tx]).b.include?(Solana::Keypair.decode_base58(nonce_value)),
             "the nonce value must not be the create's recentBlockhash"
      assert_equal 0, client.nonce_reads, "the builder never reads the nonce account"
    end
  end

  private

  # A client that answers a blockhash, and a durable-nonce account on
  # get_account_info, counting the nonce reads.
  def nonce_client(nonce_b58)
    authority = Solana::Keypair.admin.address
    buffer = [1].pack("L<") + [1].pack("L<") + Solana::Keypair.decode_base58(authority) +
             Solana::Keypair.decode_base58(nonce_b58) + [5000].pack("Q<")
    c = Object.new
    c.instance_variable_set(:@nonce_reads, 0)
    c.define_singleton_method(:nonce_reads) { @nonce_reads }
    c.define_singleton_method(:get_account_info) do |_pk, **_o|
      @nonce_reads += 1
      { "value" => { "data" => [Base64.strict_encode64(buffer), "base64"] } }
    end
    c.define_singleton_method(:get_latest_blockhash) do |**_o|
      Solana::Keypair.encode_base58((1..32).to_a.pack("C*"))
    end
    CosignFakeClient.teach(c)
  end

  def with_durable_nonce_env(pubkey)
    prev = ENV["SOLANA_DURABLE_NONCE_PUBKEY"]
    ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = pubkey
    yield
  ensure
    prev.nil? ? ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") : ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = prev
  end

  # [sig_count][sigs][header(3)][acct_count][keys][blockhash(32)][ix_count][ixs]
  # — the legacy wire both branches emit (vault_priority_fee_test.rb decodes the same).
  def decode_instructions(b64)
    bytes = Base64.decode64(b64).b
    sig_count, off = read_compact_u16(bytes, 0)
    off += sig_count * 64 + 3
    acct_count, off = read_compact_u16(bytes, off)
    keys = Array.new(acct_count) { |i| bytes[off + i * 32, 32] }
    off += acct_count * 32 + 32
    ix_count, off = read_compact_u16(bytes, off)
    Array.new(ix_count) do
      program_idx = bytes[off].ord
      off += 1
      n_accts, off = read_compact_u16(bytes, off)
      off += n_accts
      data_len, off = read_compact_u16(bytes, off)
      data = bytes[off, data_len]
      off += data_len
      { program_id_b58: Solana::Keypair.encode_base58(keys[program_idx]), data: data }
    end
  end

  def read_compact_u16(bytes, off)
    val = 0
    shift = 0
    loop do
      byte = bytes[off].ord
      off += 1
      val |= (byte & 0x7f) << shift
      break if (byte & 0x80).zero?

      shift += 7
    end
    [val, off]
  end
end
