require "test_helper"

# [unit] Solana::Vault#send_entry_wire, through the two REAL server-signed
# entry builders: the signature and the wire's block-height ceiling reach the
# caller's hook BEFORE anything is sent (Entry#record_payment_attempt! commits
# them there), and a hook that raises sends nothing. The fakes used elsewhere
# stand in for this method, so this file is what holds the real one.
class Solana::VaultSendEntryWireTest < ActiveSupport::TestCase
  def vault_with_log
    log = []
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client.define_singleton_method(:get_block_height) { |**_o| log << [:height]; 1_000 }
    client.define_singleton_method(:send_and_confirm) { |wire, **opts| log << [:send, wire, opts]; "cluster-answer" }
    [Solana::Vault.new(client: client), log]
  end

  def enter(vault, method: :token, **opts)
    user = Solana::Keypair.generate
    wallet = Solana::Keypair.encode_base58(user.public_key_bytes)
    if method == :token
      token = Solana::Keypair.encode_base58(Solana::Keypair.generate.public_key_bytes)
      vault.enter_contest_with_token(wallet, "send-entry-wire", 0, token, user_keypair: user, season_id: 1, **opts)
    else
      vault.enter_contest(wallet, "send-entry-wire", 0, currency_idx: 0, user_keypair: user, season_id: 1, **opts)
    end
  end

  # The cluster's signature for a wire: the first of its signatures.
  def first_signature(wire_base64)
    wire = Base64.decode64(wire_base64)
    Solana::Keypair.encode_base58(wire.byteslice(1, 64))
  end

  %i[token usdc].each do |method|
    test "#{method}: the hook gets the wire's own signature and its ceiling before the send" do
      vault, log = vault_with_log
      enter(vault, method: method, before_send: ->(signature, ceiling) { log << [:hook, signature, ceiling] },
                   confirm_timeout: -> { 7 })

      assert_equal %i[height hook send], log.map(&:first)
      _, signature, ceiling = log[1]
      _, wire, opts = log[2]
      assert_equal first_signature(wire), signature
      assert_equal 1_000 + Entry::Payment::BLOCKHASH_LIFETIME_BLOCKS, ceiling
      assert_equal({ timeout: 7 }, opts, "the confirm wait is resolved at send time and handed to the client")
    end

    test "#{method}: a hook that raises sends nothing" do
      vault, log = vault_with_log
      assert_raises(Entry::Payment::IllegalTransition) do
        enter(vault, method: method, before_send: ->(*) { raise Entry::Payment::IllegalTransition, "superseded" })
      end

      assert_empty log.select { |row| row.first == :send }
    end

    test "CONTROL #{method}: without a hook the send is as it was (no extra read, no timeout)" do
      vault, log = vault_with_log
      enter(vault, method: method)

      assert_equal [:send], log.map(&:first)
      assert_equal({}, log.sole[2])
    end
  end
end
