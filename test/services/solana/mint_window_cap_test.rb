require "test_helper"

# THE MINT CAP, READ AND COMPARED.
#
# turf-vault v0.26 capped entry-token minting per window instead of raising a
# flat threshold: inside the cap `mint_entry_token` is still ONE signature, and
# above it the SAME instruction demands MINT_ENTRY_TOKEN_OVER_CAP (3). Rails
# decoded `mint_window_cap` from `GovernanceConfig` and handed it back through
# `cached_governance` — and compared it against nothing. So the mint that
# crossed the cap was broadcast with one signature and came back
# `InsufficientSigners` (6046), an error naming neither the cap, nor the window,
# nor the wait, with the fee already spent and — on the Stripe path — the
# customer already charged.
#
# The count is read from `MintWindow.minted`, THE ACCOUNT THE PROGRAM ITSELF
# INCREMENTS, rather than tallied in Rails: a local tally drifts the moment
# anything mints outside this process, and the direction it drifts (low) is the
# one that lets a doomed transaction through.
class Solana::MintWindowCapTest < ActiveSupport::TestCase
  # Records what actually reached the wire. "Refuses BEFORE broadcast" is the
  # whole claim, so a test that only checked for a raise would pass just as well
  # on a guard placed after `send_and_confirm`.
  class RecordingClient
    attr_reader :broadcasts, :reads

    def initialize(accounts = {})
      @accounts = accounts
      @broadcasts = []
      @reads = []
    end

    def get_latest_blockhash(commitment: "finalized")
      Solana::Keypair.encode_base58((1..32).to_a.pack("C*"))
    end

    # `{"value" => nil}` is the RPC's definitive "no account at this address".
    def get_account_info(pubkey, **_kwargs)
      @reads << pubkey
      @accounts.fetch(pubkey, { "value" => nil })
    end

    def send_and_confirm(wire)
      @broadcasts << wire
      "BroadcastedSignature"
    end
  end

  class RecordingTx
    def add_instruction(**_kwargs) = self
    def add_signer(_kp) = self
    def serialize_base64 = "RecordedTxBase64"
  end

  class CapturingVault < Solana::Vault
    def build_tx(_signer = nil, durable_nonce: nil) = RecordingTx.new
  end

  WALLET = "HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH".freeze
  CAP = Solana::Vault::DEFAULT_MINT_WINDOW_CAP

  # The on-chain MintWindow body, byte for byte:
  #   8 discriminator + 8 window_index (i64 LE) + 4 minted (u32 LE)
  #   + 1 bump + 16 _reserved
  #
  # Built here from the LAYOUT rather than from the reader's own constants, so a
  # decoder that moved its offsets fails instead of agreeing with itself.
  def mint_window_account(window_index, minted)
    body = ("\x00".b * 8) +
           [window_index].pack("q<") +
           [minted].pack("L<") +
           [254].pack("C") +
           ("\x00".b * 16)
    { "value" => { "data" => [Base64.strict_encode64(body), "base64"] } }
  end

  def governance
    { thresholds: [], mint_window_seconds: Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS,
      mint_window_cap: CAP }
  end

  # A vault whose current window already holds `minted` mints. Passing
  # `minted: nil` leaves the account absent, which is how a window that has
  # minted nothing reads on chain.
  def vault_with(minted:, &blk)
    client = nil
    Solana::Config.stub(:governance?, true) do
      index = Time.current.to_i.div(Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS)
      probe = CapturingVault.new(client: RecordingClient.new)
      pda, _ = probe.mint_window_pda(index)
      accounts = minted.nil? ? {} : { Solana::Keypair.encode_base58(pda) => mint_window_account(index, minted) }
      client = RecordingClient.new(accounts)
      v = CapturingVault.new(client: client)
      v.stub(:cached_governance, governance) { blk.call(v, client, index) }
    end
  end

  def mint(vault, **opts)
    vault.mint_entry_token(wallet_address: WALLET, source: :operator,
                           source_ref: "cap-test-#{SecureRandom.hex(4)}", **opts)
  end

  # ── THE COUNT ─────────────────────────────────────────────────────────────

  test "the window count is decoded off the MintWindow account the program increments" do
    vault_with(minted: 137) do |v, _client, index|
      assert_equal 137, v.read_mint_window(index)

      usage = v.mint_window_usage
      assert_equal index, usage[:window_index]
      assert_equal 137, usage[:minted]
      assert_equal CAP, usage[:cap]
      assert_equal CAP - 137, usage[:remaining]
    end
  end

  # `init_if_needed` creates the account on the window's FIRST mint, so "no
  # account" and "no mints yet" are the same on-chain state. Reading the absence
  # as unknown would refuse every first mint of every window.
  test "a window whose account does not exist yet counts as zero, not unknown" do
    vault_with(minted: nil) do |v, _client, index|
      assert_equal 0, v.read_mint_window(index)
      assert_equal CAP, v.mint_window_remaining
    end
  end

  # ── THE REFUSAL ───────────────────────────────────────────────────────────

  test "a mint above the window cap refuses BEFORE it is broadcast" do
    vault_with(minted: CAP) do |v, client|
      error = assert_raises(Solana::Vault::MintWindowCapReachedError) { mint(v) }

      assert_empty client.broadcasts,
                   "the refusal must land before send_and_confirm — after it, the fee is spent " \
                   "and the customer is already charged"
      assert_match(/#{CAP} of its #{CAP}/, error.message, "the message must name the count and the cap")
      assert_match(/MINT_ENTRY_TOKEN_OVER_CAP \(3\)/, error.message, "and what the mint would have needed")
      assert_match(/window rolls/, error.message, "and the wait, which is the actual remedy")
    end
  end

  # THE BOUNDARY, and it is the program's: `already_minted < cap` picks the
  # 1-signature action, so the mint that CROSSES the cap is itself the first one
  # to need three — not the one after it. Off by one here and Rails refuses a
  # mint the chain would have taken, every day, forever.
  test "the last mint inside the cap still goes through" do
    vault_with(minted: CAP - 1) do |v, client|
      mint(v)
      assert_equal 1, client.broadcasts.length, "minted == cap - 1 is the 250th mint, and it is allowed"
    end
  end

  test "the refusal is a ThresholdUnreachableError, so existing rescues still catch it" do
    assert_operator Solana::Vault::MintWindowCapReachedError, :<, Solana::Vault::ThresholdUnreachableError
  end

  # ── THE RESERVE ───────────────────────────────────────────────────────────

  test "an unattended path yields the window's last slots; paid fulfilment takes them" do
    reserve = Solana::Vault::UNATTENDED_MINT_WINDOW_RESERVE
    minted  = CAP - reserve   # exactly on the grinder's ceiling, well under the cap

    vault_with(minted: minted) do |v, client|
      error = assert_raises(Solana::Vault::MintWindowCapReachedError) { mint(v, reserve: reserve) }
      assert_match(/holding #{reserve} back for paid fulfilment/, error.message)
      assert_empty client.broadcasts
    end

    # The SAME window, the same count — the paid path passes no reserve and is
    # served. This is the whole point of the reserve: not a lower cap, a
    # priority.
    vault_with(minted: minted) do |v, client|
      mint(v)
      assert_equal 1, client.broadcasts.length
    end
  end

  # A RESERVE IS A PRIORITY, NOT A SHUTDOWN. The reserve is a fixed count and
  # the cap is retunable on chain, so a cap lowered to at or below the reserve
  # would leave the unattended path a ceiling of zero — refusing every grant
  # forever, and quietly, since a cap refusal deliberately files no per-user
  # ErrorLog. An operator throttling the platform must not silently switch off
  # level-up rewards as a side effect.
  test "a cap smaller than the reserve still leaves the unattended path some budget" do
    tiny = 10
    reserve = Solana::Vault::UNATTENDED_MINT_WINDOW_RESERVE   # 25, larger than the cap
    assert_operator reserve, :>, tiny, "this test is only meaningful while the reserve exceeds the cap"

    Solana::Config.stub(:governance?, true) do
      index = Time.current.to_i.div(Solana::Vault::DEFAULT_MINT_WINDOW_SECONDS)
      probe = CapturingVault.new(client: RecordingClient.new)
      pda, _ = probe.mint_window_pda(index)
      client = RecordingClient.new(Solana::Keypair.encode_base58(pda) => mint_window_account(index, 0))
      v = CapturingVault.new(client: client)

      v.stub(:cached_governance, governance.merge(mint_window_cap: tiny)) do
        mint(v, reserve: reserve)
        assert_equal 1, client.broadcasts.length,
                     "an empty window must serve the grinder even when the reserve exceeds the cap"
      end
    end
  end

  # ── WHAT IT MUST NOT DO ───────────────────────────────────────────────────

  # The v0.25 control. Governance off is the PRODUCTION default today: there is
  # no GovernanceConfig, no MintWindow and no cap, so the guard must be wholly
  # inert — and must not spend an RPC asking about an account that cannot exist.
  test "the guard is inert in the v0.25 shape and reads no window account" do
    client = RecordingClient.new
    Solana::Config.stub(:governance?, false) do
      v = CapturingVault.new(client: client)
      mint(v)
    end

    assert_equal 1, client.broadcasts.length
    assert_empty client.reads, "the v0.25 program has no MintWindow account to ask about"
  end

  # FAILS OPEN, deliberately. The count rides the same RPC the mint itself
  # needs, so a read failure is nearly always a transport problem the mint is
  # about to hit anyway — and refusing on ignorance would convert an RPC blip
  # into a refused Stripe fulfilment, which is worse than the behaviour this
  # guard replaces. Proceeding leaves the chain as the authority, exactly as
  # today.
  test "an unreadable count proceeds rather than refusing, and reports itself as unknown" do
    Solana::Config.stub(:governance?, true) do
      client = Class.new(RecordingClient) do
        def get_account_info(_pubkey, **_kwargs) = raise(IOError, "rpc unreachable")
      end.new
      v = CapturingVault.new(client: client)

      v.stub(:cached_governance, governance) do
        usage = v.mint_window_usage
        assert_nil usage[:minted],   "an unreadable count is unknown, not zero"
        assert_nil usage[:remaining], "and must not read as a full budget"

        mint(v)
        assert_equal 1, client.broadcasts.length, "ignorance must not stop a mint"
      end
    end
  end
end
