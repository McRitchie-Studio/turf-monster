# Shared Solana::Vault stand-in for tests.
# Subsumes the two inline FakeVault classes that used to live in
# token_purchase_job_test.rb and contests_controller_test.rb. Extracted here
# (LW1 in the Stage 3 audit) so the entry-token / dev-mint / balance tests
# that were marked `skip "needs FakeVault methods"` can run.
#
# Usage:
#   vault = FakeVault.new(tokens: [{ pda: "tpda_1" }])
#   Solana::Vault.stub :new, vault do
#     # code under test
#   end
#   assert_equal 1, vault.enter_calls.length
#
# Configurable:
#   fail_after:        integer N → raise on the (N+1)-th mint_entry_token call
#   starting_sequence: integer  → first mint's sequence (for resume tests)
#   tokens:            array    → seeds list_entry_tokens (drives has-tokens branches)
class FakeVault
  attr_reader :mint_calls, :transfer_calls, :enter_calls, :ensure_account_calls,
              :fund_calls, :deposit_calls

  def initialize(fail_after: nil, starting_sequence: 0, tokens: [], signature_statuses: {},
                 usdc_balance: nil, usdc_balance_raises: false, account_infos: {}, signatures: {},
                 send_raises: nil, season: { season_id: 1 }, season_raises: nil, seasons: nil)
    @fail_after = fail_after
    @starting_sequence = starting_sequence
    @tokens = tokens
    @signature_statuses = signature_statuses
    @usdc_balance = usdc_balance            # uiAmount dollars to return from get_token_account_balance
    @usdc_balance_raises = usdc_balance_raises
    @account_infos = account_infos          # pda_b58 => {"value" => ...} for get_account_info (PDA-exists check)
    @signatures = signatures                 # pda_b58 => [{ "signature" =>, "err" => }] for getSignaturesForAddress
    @send_raises = send_raises               # send_transaction fault (offramp send tests)
    @season = season
    @season_raises = season_raises
    @seasons = seasons || Array(season)
    @mint_calls = []
    @transfer_calls = []
    @enter_calls = []
    @ensure_account_calls = []
    @fund_calls = []
    @deposit_calls = []
  end

  # --- Solana RPC client stub (recovery flow) ---
  #
  # Returns a FakeSolanaClient seeded with the signature_statuses map from
  # initialize. The recovery action calls
  # `Solana::Vault.new.client.confirm_transaction(sig).dig("value", 0)`,
  # so the stub mirrors that envelope shape.
  def client
    @client ||= FakeSolanaClient.new(@signature_statuses,
                                     usdc_balance: @usdc_balance,
                                     usdc_balance_raises: @usdc_balance_raises,
                                     account_infos: @account_infos,
                                     signatures: @signatures,
                                     send_raises: @send_raises)
  end

  # Used by ContestsController#create / #rebuild_create_tx. Returns the same
  # envelope shape as the real Solana::Vault#build_create_contest.
  def build_create_contest(wallet_address, contest_slug, **_params)
    @create_contest_calls ||= []
    @create_contest_calls << { wallet: wallet_address, slug: contest_slug, params: _params }
    { serialized_tx: "FAKE_TX_create_#{contest_slug}", contest_pda: "cpda-#{contest_slug}" }
  end

  def create_contest_calls
    @create_contest_calls ||= []
  end

  # Used by Contest#create_onchain! (server-funded path; the after_create
  # callback is skipped in test env, so tests invoke it directly). Records
  # the kwargs so tests can assert the entry_fee_by_currency schedule that
  # would hit the chain.
  def create_contest_server_funded(contest_slug:, **kwargs)
    @server_funded_calls ||= []
    @server_funded_calls << { contest_slug: contest_slug, **kwargs }
    { tx_signature: "fake-create-#{contest_slug}", contest_pda: "cpda-#{contest_slug}" }
  end

  def server_funded_calls
    @server_funded_calls ||= []
  end

  def get_season(_season_id, commitment: "confirmed")
    raise @season_raises if @season_raises

    @season
  end

  def list_seasons(commitment: "confirmed")
    @seasons
  end

  # Used by ApplicationController#fetch_navbar_hydrate (USDC/USDT/SOL read).
  # Seed via the wallet_balances writer; nil simulates an RPC flake (the
  # caller treats a non-Hash as unknown and emits nils).
  #
  # wallet_balances_raises models a getTokenAccountsByOwner RPC FLAKE the way the
  # real Solana::Vault does (2026-06-13): the swallowing default path returns
  # `usdc: 0` (indistinguishable from a genuine empty wallet), but the
  # funding-decision path (raise_on_read_error: true) RE-RAISES so callers can
  # fail OPEN instead of false-blocking a funded user. Set it true to exercise
  # the conflation Avi flagged as previously untested.
  attr_writer :wallet_balances, :wallet_balances_raises

  def fetch_wallet_balances(_wallet_address, raise_on_read_error: false)
    if defined?(@wallet_balances_raises) && @wallet_balances_raises
      raise Solana::Client::RpcError, "simulated token-accounts RPC flake" if raise_on_read_error

      return { sol: 0.0, usdc: 0, usdt: 0, tokens: {} }
    end
    defined?(@wallet_balances) ? @wallet_balances : { sol: 0.0, usdc: 0.0, usdt: 0.0 }
  end

  # Recovery flow re-derives the entry PDA server-side before verifying the
  # signature. The real Vault returns [pubkey_bytes, bump]; tests stub
  # Solana::Keypair.encode_base58 to identity, so a deterministic value here
  # is enough to exercise the derive → verify → confirm path.
  def entry_pda(_contest_slug, _wallet_address, _entry_num)
    ["epda-derived", 255]
  end

  # --- Token minting (TokenPurchaseJob, dev_mint) ---

  def mint_entry_token(wallet_address:, source:, source_ref:, **_opts)
    @mint_calls << source_ref
    raise StandardError, "simulated chain failure" if @fail_after && @mint_calls.length > @fail_after
    seq = @starting_sequence + @mint_calls.length - 1
    { signature: "sig_#{seq}_#{SecureRandom.hex(2)}", pda: "pda-seq-#{seq}", sequence: seq }
  end

  # `tokens:` is usually an Array applied to EVERY address. Pass a Hash
  # (address => array) instead to model a combo (web2+web3) account whose two
  # wallets hold different tokens — e.g. a web3-owned token the web2 server-sign
  # path must NOT pick. An address missing from the Hash returns [].
  def list_entry_tokens(wallet, **_opts)
    return (@tokens[wallet] || []).dup if @tokens.is_a?(Hash)
    @tokens.dup
  end

  def next_entry_token_sequence(_wallet)
    @starting_sequence + @mint_calls.length
  end

  # --- Offchain USDC transfer (legacy contest entry path) ---

  def transfer_from_user(user, amount, mint:)
    @transfer_calls << { user_id: user.id, amount: amount, mint: mint }
    { signature: "fake-transfer-sig-#{SecureRandom.hex(2)}" }
  end

  # --- On-chain contest entry ---

  def enter_contest_with_token(wallet, slug, entry_number, token_pda, user_keypair:, season_id:)
    @enter_calls << {
      method: :enter_contest_with_token,
      wallet: wallet, slug: slug, entry_number: entry_number,
      token_pda: token_pda, season_id: season_id
    }
    { signature: "fake-enter-with-token-#{SecureRandom.hex(2)}", entry_pda: "epda-#{SecureRandom.hex(2)}" }
  end

  def enter_contest(wallet, slug, entry_number, season_id: nil)
    @enter_calls << {
      method: :enter_contest,
      wallet: wallet, slug: slug, entry_number: entry_number, season_id: season_id
    }
    { signature: "fake-enter-#{SecureRandom.hex(2)}", entry_pda: "epda-#{SecureRandom.hex(2)}" }
  end

  # Server-signed managed-wallet USDC entry (unified-funding web2 fallback).
  # Mirrors Solana::Vault#enter_contest_with_usdc: resolves wallet from the
  # user's web2 address, pins currency_idx 0 (USDC, never USDT for web2), and
  # records into enter_calls so a controller test can assert the web2 USDC
  # funding path fired (vs the token path).
  def enter_contest_with_usdc(user:, contest:, entry_num:)
    @enter_calls << {
      method: :enter_contest_with_usdc,
      wallet: user.web2_solana_address, slug: contest.slug,
      entry_number: entry_num, currency_idx: 0, season_id: contest.season_id
    }
    { signature: "fake-enter-usdc-#{SecureRandom.hex(2)}", entry_pda: "epda-#{SecureRandom.hex(2)}" }
  end

  # --- Build-only partial-signed TXs (Phantom co-sign flow) ---
  #
  # Used by ContestsController#prepare_entry. Returns the same envelope shape
  # as the real Solana::Vault#build_enter_contest_direct: serialized_tx plus
  # the predicted entry PDA the user's TX will create.
  # v0.16: renamed from build_enter_contest_direct; now takes currency_idx (0=USDC).
  # Token-funded Phantom entry (ContestsController#prepare_entry). Same return
  # shape as #build_enter_contest — the caller only ever forwards serialized_tx
  # and entry_pda — with the token PDA recorded so a test can assert WHICH token
  # the server picked.
  def build_enter_contest_with_token(wallet_address, contest_slug, entry_num, entry_token_pda_b58, season_id: nil)
    @enter_calls << {
      method: :build_enter_contest_with_token,
      wallet: wallet_address, slug: contest_slug,
      entry_number: entry_num, entry_token_pda: entry_token_pda_b58, season_id: season_id
    }
    {
      serialized_tx: "FAKE_TOKEN_TX_#{contest_slug}_#{entry_num}",
      entry_pda: "epda-#{contest_slug}-#{wallet_address[0, 4]}-#{entry_num}"
    }
  end

  def build_enter_contest(wallet_address, contest_slug, entry_num, currency_idx: 0, season_id: nil)
    @enter_calls << {
      method: :build_enter_contest,
      wallet: wallet_address, slug: contest_slug,
      entry_number: entry_num, currency_idx: currency_idx, season_id: season_id
    }
    {
      serialized_tx: "FAKE_TX_#{contest_slug}_#{entry_num}",
      entry_pda: "epda-#{contest_slug}-#{wallet_address[0, 4]}-#{entry_num}"
    }
  end

  # Used by ContestsController#confirm_onchain_entry (Phantom-FIRST flow). The
  # real Vault cosigns the Phantom-signed wire bytes with the admin keypair,
  # simulates, broadcasts, and returns the confirmed tx signature. The fake
  # records the call and returns a deterministic signature.
  attr_writer :cosign_broadcast_raises

  def cosign_and_broadcast_entry(signed_wire_base64)
    @cosign_broadcast_calls ||= []
    @cosign_broadcast_calls << signed_wire_base64
    raise StandardError, @cosign_broadcast_raises if @cosign_broadcast_raises
    @cosign_broadcast_signature ||= "fake-cosign-broadcast-sig"
  end

  attr_writer :cosign_broadcast_signature

  def cosign_broadcast_calls
    @cosign_broadcast_calls ||= []
  end

  attr_writer :create_cosign_broadcast_raises, :create_cosign_safe_raises,
              :create_cosign_broadcast_signature

  def assert_create_contest_cosign_safe!(signed_wire_base64, wallet_address:, contest_slug:, onchain_params:)
    @create_cosign_safe_calls ||= []
    @create_cosign_safe_calls << {
      wire: signed_wire_base64,
      wallet_address: wallet_address,
      contest_slug: contest_slug,
      onchain_params: onchain_params
    }
    raise Solana::Vault::UnsafeCosignError, @create_cosign_safe_raises if @create_cosign_safe_raises
    true
  end

  def create_cosign_safe_calls
    @create_cosign_safe_calls ||= []
  end

  def cosign_and_broadcast_create_contest(signed_wire_base64)
    @create_cosign_broadcast_calls ||= []
    @create_cosign_broadcast_calls << signed_wire_base64
    raise StandardError, @create_cosign_broadcast_raises if @create_cosign_broadcast_raises
    @create_cosign_broadcast_signature ||= "fake-create-cosign-broadcast-sig"
  end

  def create_cosign_broadcast_calls
    @create_cosign_broadcast_calls ||= []
  end

  # Used by ContestsController#confirm_onchain_entry (audit C1). The real Vault
  # SEMANTICALLY validates the Phantom-signed wire BEFORE the admin cosigns —
  # raising Solana::Vault::UnsafeCosignError on a tx that doesn't match the
  # prepared entry. The fake records the call and is a no-op (safe) by default;
  # set `cosign_safe_raises = "<reason>"` to exercise the controller's
  # tx_rejected (422) rescue path without broadcasting.
  attr_writer :cosign_safe_raises

  # `entry_token_pda:` mirrors the real guard: the EntryTokenAccount the server
  # prepared this entry against (nil = the currency transfer). Recorded so a test
  # can assert the controller handed the guard its OWN decision rather than
  # anything the client sent.
  def assert_entry_cosign_safe!(signed_wire_base64, entry:, wallet_address:, entry_token_pda: nil)
    @cosign_safe_calls ||= []
    @cosign_safe_calls << { wire: signed_wire_base64, entry: entry, wallet_address: wallet_address,
                            entry_token_pda: entry_token_pda }
    raise Solana::Vault::UnsafeCosignError, @cosign_safe_raises if @cosign_safe_raises
    true
  end

  def cosign_safe_calls
    @cosign_safe_calls ||= []
  end

  # Used by ContestsController#confirm_onchain_entry. Real Vault returns
  # [pda_bytes, bump] and the controller passes pda_bytes through
  # Solana::Keypair.encode_base58. For tests, return a tuple whose first
  # element is already a string and stub Solana::Keypair.encode_base58 to
  # identity when calling confirm_onchain_entry.
  def entry_pda(contest_slug, wallet_address, entry_num)
    ["epda-#{contest_slug}-#{wallet_address[0, 4]}-#{entry_num}", 255]
  end

  # Mirrors Solana::Vault#next_free_entry_index. The FakeVault world has no
  # orphaned on-chain PDAs, so the lowest slot not in `skip` is free — which
  # reproduces the old "first entry is index 0" behavior the entry-flow tests
  # assume. `@account_infos` can seed "occupied" slots if a test needs them.
  def next_free_entry_index(contest_slug, wallet_address, max:, skip: [])
    skip = Array(skip).map(&:to_i)
    (0...max).find do |n|
      next false if skip.include?(n)
      pda = entry_pda(contest_slug, wallet_address, n).first
      info = @account_infos[pda]
      info.nil? || info["value"].nil?
    end
  end

  # Used by ContestsController#prepare_lock_time (Phantom-signed lock flow).
  def build_set_contest_lock_time(contest_slug, lock_timestamp, admin_pubkey:)
    @lock_calls ||= []
    @lock_calls << { slug: contest_slug, lock_timestamp: lock_timestamp, admin: admin_pubkey }
    { serialized_tx: "FAKE_TX_lock_#{contest_slug}_#{lock_timestamp}" }
  end

  def lock_calls
    @lock_calls ||= []
  end

  # Used by ContestsController#prepare_conclusion_time (Phantom-signed flow).
  def build_set_contest_conclusion_time(contest_slug, conclusion_timestamp, admin_pubkey:)
    @conclusion_calls ||= []
    @conclusion_calls << { slug: contest_slug, conclusion_timestamp: conclusion_timestamp, admin: admin_pubkey }
    { serialized_tx: "FAKE_TX_conclude_#{contest_slug}_#{conclusion_timestamp}" }
  end

  def conclusion_calls
    @conclusion_calls ||= []
  end

  # Used by ContestsController#confirm_lock_time (mirrors entry_pda shape).
  def contest_pda(contest_slug)
    ["cpda-#{contest_slug}", 254]
  end

  # --- PDA / ATA bootstrapping (no-op stubs) ---

  def ensure_user_account(wallet, username: nil)
    # v0.16: callers MUST pass username (>= 3 chars) — production Vault
    # rescues to a Ruby ArgumentError client-side before the chain call.
    # Test signature mirrors the real one.
    @ensure_account_calls << { wallet: wallet, username: username }
    { created: false }
  end

  def ensure_ata(wallet, mint:)
    @ensure_ata_calls ||= []
    @ensure_ata_calls << { wallet: wallet, mint: mint }
    { ata: "fake-ata-#{wallet[0, 4]}-#{mint[0, 4]}", created: false }
  end

  # Recorded { wallet:, mint: } per ensure_ata call — lets prepare_entry tests
  # assert the ATA matches the selected currency (USDC vs USDT mint).
  def ensure_ata_calls
    @ensure_ata_calls ||= []
  end

  # --- Deposit flow (StripeDepositJob) ---

  def fund_user(wallet, lamports)
    @fund_calls << { wallet: wallet, lamports: lamports }
    { signature: "fake-fund-#{SecureRandom.hex(2)}" }
  end

  def deposit(_user_keypair, lamports)
    @deposit_calls << { lamports: lamports }
    "fake-deposit-sig-#{SecureRandom.hex(2)}"
  end

  # --- Reading on-chain state (seeds + balance helpers) ---

  attr_writer :sync_balance_seeds

  def sync_balance(_wallet)
    seeds = (@sync_balance_seeds || 0).to_i
    { balance_dollars: 0.0, seeds: seeds, level: User.level_for(seeds) }
  end

  def seeds_for_entry(_entry_number)
    25
  end

  # --- Contest close / cancel (unused-instructions cleanup) ---

  def close_contest(contest_slug)
    @close_calls ||= []
    @close_calls << contest_slug
    { signature: "fake-close-#{SecureRandom.hex(2)}" }
  end

  def close_calls
    @close_calls ||= []
  end

  # Real Vault returns the full on-chain Contest hash; tests only need :creator.
  attr_writer :read_contest_creator

  def read_contest(contest_slug, **_opts)
    { creator: (@read_contest_creator || "CreAtorXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), pda: "cpda-#{contest_slug}", status: "Open" }
  end

  def build_cancel_contest(contest_slug, creator_pubkey:, cosigner_pubkey:)
    @cancel_calls ||= []
    @cancel_calls << { slug: contest_slug, creator: creator_pubkey, cosigner: cosigner_pubkey }
    { serialized_tx: "FAKE_TX_cancel_#{contest_slug}" }
  end

  def cancel_calls
    @cancel_calls ||= []
  end

  # --- Offramp USDC send (Cdp::OfframpSendJob / Cdp::OfframpSendsController) ---
  #
  # Real Vault#build_user_usdc_transfer returns { wire_base64:, signature: }
  # WITHOUT broadcasting (the job persists the signature first, then
  # broadcasts via vault.client.send_transaction). Configure:
  #   offramp_send_signature: the canned tx signature (default below)
  #   offramp_build_raises:   message → raise at build time

  attr_writer :offramp_send_signature, :offramp_build_raises

  def build_user_usdc_transfer(user_keypair:, destination_token_account:, amount_lamports:)
    @offramp_build_calls ||= []
    @offramp_build_calls << {
      authority: user_keypair.address,
      destination: destination_token_account,
      amount: amount_lamports
    }
    raise StandardError, @offramp_build_raises if @offramp_build_raises
    {
      wire_base64: "FAKE_WIRE_offramp_#{amount_lamports}",
      signature: (@offramp_send_signature || "FakeOfframpSendSig")
    }
  end

  def offramp_build_calls
    @offramp_build_calls ||= []
  end

  # Phantom flavor — unsigned single-signer tx envelope.
  def build_user_usdc_transfer_unsigned(wallet_address:, destination_token_account:, amount_lamports:)
    @offramp_unsigned_calls ||= []
    @offramp_unsigned_calls << {
      wallet: wallet_address,
      destination: destination_token_account,
      amount: amount_lamports
    }
    { serialized_tx: "FAKE_TX_offramp_#{wallet_address[0, 4]}_#{amount_lamports}" }
  end

  def offramp_unsigned_calls
    @offramp_unsigned_calls ||= []
  end

  # --- Currency registry + sweep (unused-instructions cleanup) ---

  def read_vault_state(**_opts)
    @vault_state || {
      pda: "vault-pda",
      treasury_authority: "TreaSuryXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
      accepted_currencies: Array.new(16) { |i| { slot: i, mint: "11111111111111111111111111111111", op_rev_ata: "11111111111111111111111111111111", kind: 0, active: false } }
    }
  end

  attr_writer :vault_state

  def build_register_currency(cosigner_pubkey:, mint:, kind: 0)
    @register_calls ||= []
    @register_calls << { cosigner: cosigner_pubkey, mint: mint, kind: kind }
    { serialized_tx: "FAKE_TX_register_#{mint}", op_rev_ata: "oprev-#{mint[0, 4]}" }
  end

  def register_calls
    @register_calls ||= []
  end

  def build_deactivate_currency(cosigner_pubkey:, currency_idx:)
    @deactivate_calls ||= []
    @deactivate_calls << { cosigner: cosigner_pubkey, currency_idx: currency_idx }
    { serialized_tx: "FAKE_TX_deactivate_#{currency_idx}" }
  end

  def deactivate_calls
    @deactivate_calls ||= []
  end

  def treasury_ata_for(mint)
    "treasury-ata-#{mint[0, 4]}"
  end

  def op_rev_ata_pda(mint)
    ["oprev-pda-#{mint[0, 4]}", 253]
  end

  def vault_state_pda
    ["vault-state-pda", 255]
  end

  def build_sweep_operator_revenue(cosigner_pubkey:, currency_mint:, treasury_ata_pubkey:, amount: 0)
    @sweep_calls ||= []
    @sweep_calls << { cosigner: cosigner_pubkey, currency_mint: currency_mint, treasury_ata: treasury_ata_pubkey, amount: amount }
    { serialized_tx: "FAKE_TX_sweep_#{currency_mint[0, 4]}" }
  end

  def sweep_calls
    @sweep_calls ||= []
  end

  # --- Quest seed grants (v0.23 quests: username / chat / newsletter / invite) ---
  #
  # Mirrors Solana::Vault#grant_seeds + #seeds_for_quest. Records every grant so
  # a test can assert exactly ONE grant fired (the once-ever quest gate), and
  # returns the same { signature, pda, seeds_earned, seeds_total, seeds_level }
  # shape the controllers slice into their StateFanout JSON payload.
  #
  #   quest_seed_reward → override what seeds_for_quest returns (default 25)
  #   grant_seeds_total → override the running on-chain total (default = amount)
  attr_writer :quest_seed_reward, :grant_seeds_total, :grant_seeds_error

  def grant_seeds(wallet_address:, amount:, kind:, invitee: nil)
    @grant_calls ||= []
    @grant_calls << { wallet: wallet_address, amount: amount, kind: kind, invitee: invitee }
    raise @grant_seeds_error if @grant_seeds_error

    total = (@grant_seeds_total || amount).to_i
    {
      signature:    "fake-grant-#{kind}-#{SecureRandom.hex(2)}",
      pda:          "grant-pda-#{kind}",
      seeds_earned: amount,
      seeds_total:  total,
      seeds_level:  User.level_for(total)
    }
  end

  def grant_calls
    @grant_calls ||= []
  end

  def seeds_for_quest(_kind)
    @quest_seed_reward || 25
  end

  # Used by AccountsController#confirm_username (Phantom set_username step 2). The
  # real Vault returns [pda_bytes, bump]; the controller passes pda_bytes through
  # Solana::Keypair.encode_base58 (stubbed to identity in the confirm test), so a
  # deterministic string here is enough to exercise the derive → verify → mirror path.
  def user_account_pda(wallet_address)
    ["upda-#{wallet_address.to_s[0, 6]}", 254]
  end

  # Custodial (managed-wallet) on-chain username co-sign — see
  # AccountsController#update_username. The controller ignores the return value
  # (it mirrors the username to the DB itself), so a recorded no-op is enough.
  def set_username(wallet_address, username, user_keypair: nil)
    @set_username_calls ||= []
    @set_username_calls << { wallet: wallet_address, username: username }
    { signature: "fake-set-username-#{SecureRandom.hex(2)}" }
  end

  def set_username_calls
    @set_username_calls ||= []
  end
end

# Mirrors the relevant slice of Solana::Client used by
# ContestsController#recover_pending_entry. The real RPC returns
# {"value" => [{"err"=>..., "confirmationStatus"=>"confirmed"|"finalized"|"processed"}, ...]}
# (one entry per requested signature); we always batch a single signature
# here, so the array has at most one element. An unknown signature
# returns {"value" => [nil]} per the JSON-RPC spec.
class FakeSolanaClient
  def initialize(statuses, usdc_balance: nil, usdc_balance_raises: false, account_infos: {},
                 signatures: {}, send_raises: nil, transactions: {})
    @statuses = statuses || {}
    @usdc_balance = usdc_balance
    @usdc_balance_raises = usdc_balance_raises
    @account_infos = account_infos || {}
    @signatures = signatures || {}
    @send_raises = send_raises          # exception (or message) raised by send_transaction
    @transactions = transactions || {}  # signature => get_transaction payload
  end

  def confirm_transaction(signature)
    { "value" => [@statuses[signature]] }
  end

  # Cdp::OfframpSendJob broadcasts the pre-signed wire here AFTER persisting
  # the signature. Records every call; @send_raises simulates a broadcast
  # fault (the verify-before-retry path must own recovery).
  def send_transaction(wire_base64, **_opts)
    @sent_transactions ||= []
    @sent_transactions << wire_base64
    if @send_raises
      raise @send_raises if @send_raises.is_a?(Exception) || @send_raises.is_a?(Class)
      raise Solana::Client::RpcError, @send_raises.to_s
    end
    "fake-broadcast-sig"
  end

  def sent_transactions
    @sent_transactions ||= []
  end

  # Cdp::OfframpSendsController#verify_reported_signature! (Phantom sent
  # report). nil (default) = "not found on-chain".
  def get_transaction(signature, **_opts)
    @transactions[signature]
  end

  # ContestsController#insufficient_usdc_error reads value/uiAmount. A nil
  # @usdc_balance simulates a failed/unreadable response (returns nil);
  # @usdc_balance_raises simulates an RPC exception (the hardened code must
  # treat BOTH as a hard block, not a $0 pass).
  def get_token_account_balance(_ata_b58)
    raise StandardError, "simulated RPC failure" if @usdc_balance_raises
    return nil if @usdc_balance.nil?
    { "value" => { "uiAmount" => @usdc_balance, "amount" => (@usdc_balance * 1_000_000).to_i.to_s } }
  end

  # ContestsController#onchain_create_precheck reads dig("value") to decide
  # whether the contest PDA already exists on-chain.
  def get_account_info(pda_b58)
    @account_infos[pda_b58]
  end

  # Entries::OnchainReconciler#oldest_success_signature reaches the raw JSON-RPC
  # via `client.send(:call, "getSignaturesForAddress", [pda, {...}])` — the same
  # private entrypoint Solana::Vault#list_entry_tokens uses. Return the
  # configured per-PDA signature list (newest-first, like the real RPC).
  def call(method, params)
    case method
    when "getSignaturesForAddress"
      @signatures[params[0]] || []
    end
  end
end
