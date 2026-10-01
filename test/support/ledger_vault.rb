require_relative "fake_vault"

# A FakeVault that KEEPS THE CHAIN'S BOOKS for a managed entry, for the tests
# whose whole question is "was anything spent, and how many times?"
# (test/services/entries/api_submission_test.rb, the agent API's entry tests).
#
# FakeVault records that enter_contest_with_token was CALLED and hands back a
# random signature. That cannot tell a single spend from a double one: its
# token is never consumed, and its ticket is never on chain. This double does
# what the program does:
#
#   * a token-funded entry CONSUMES the token it names, and refuses a consumed one;
#   * a USDC entry DEBITS the wallet's USDC, and refuses an underfunded one;
#   * either way the ContestEntry ticket then EXISTS at (contest, wallet, slot),
#     with the signature that created it, and a second entry at that slot is
#     refused the way the System program refuses to allocate twice.
#
# So `tickets.size` and `spent_tokens.size` are the number of real spends, and
# the ticket is visible to everything that reads the chain afterwards
# (next_free_entry_index, the reconciler's probe, Entries::ApiSubmission).
#
# THE SIGNATURES ARE THE REAL ONES. Every method the entry path calls is
# defined here with the parameter list Solana::Vault declares, and
# test/support/ledger_vault_signature_test.rb fails if they drift. A double
# that took `**kwargs` would accept a misspelt keyword the real method refuses.
#
# FAILURE INJECTION (`fail_next_enter`), each a different fact about the spend:
#
#   :rejected   the simulation refuses. Nothing moves. Definite.
#   :unlanded   the transaction is never confirmed and never lands. Nothing
#               moves, but the caller only sees a timeout.
#   :lost       the transaction LANDS and the confirmation is lost: the same
#               timeout, with the money gone. The case idempotency exists for.
class LedgerVault < FakeVault
  SIMULATION_FAILED = "Transaction simulation failed: Error processing Instruction 0: ".freeze

  attr_accessor :fail_next_enter, :token_read_raises, :before_enter
  attr_reader :tickets

  def initialize(tokens: [], usdc: 0.0, **options)
    @ledger_accounts = {}
    @ledger_signatures = {}
    super(tokens: tokens, account_infos: @ledger_accounts, signatures: @ledger_signatures, **options)
    self.wallet_balances = { sol: 0.1, usdc: usdc, usdt: 0.0 }
    @tickets = []
    @sequence = 0
  end

  def spent_tokens
    Array(@tokens).select { |token| token[:consumed] }
  end

  def usdc_balance
    @wallet_balances[:usdc]
  end

  def grant_token(pda)
    @tokens << { pda: pda, consumed: false }
  end

  def list_entry_tokens(wallet_address, commitment: "confirmed")
    raise Solana::Client::RpcError, "simulated getProgramAccounts failure" if token_read_raises

    super
  end

  def enter_contest_with_token(wallet_address, contest_slug, entry_num, entry_token_pda_b58,
                               user_keypair:, season_id: nil)
    raise "user_keypair required (OPSEC-004)" unless user_keypair

    @enter_calls << { method: :enter_contest_with_token, wallet: wallet_address, slug: contest_slug,
                      entry_number: entry_num, token_pda: entry_token_pda_b58, season_id: season_id }
    token = tokens_for(wallet_address).find { |candidate| candidate[:pda] == entry_token_pda_b58 }
    if token.nil? || token[:consumed]
      raise Solana::Client::RpcError, "#{SIMULATION_FAILED}custom program error: 0x177f"
    end

    land!(wallet_address, contest_slug, entry_num, :token) { token[:consumed] = true }
  end

  def enter_contest_with_usdc(user:, contest:, entry_num:)
    wallet = user.web2_solana_address
    @enter_calls << { method: :enter_contest_with_usdc, wallet: wallet, slug: contest.slug,
                      entry_number: entry_num, currency_idx: 0, season_id: contest.season_id }
    fee = contest.entry_fee_cents / 100.0
    raise Solana::Client::RpcError, "#{SIMULATION_FAILED}custom program error: 0x1" if usdc_balance < fee

    land!(wallet, contest.slug, entry_num, :usdc) { @wallet_balances[:usdc] -= fee }
  end

  def next_free_entry_index(contest_slug, wallet_address, max:, skip: [])
    super
  end

  def ensure_user_account(wallet_address, username: nil)
    super
  end

  def fetch_wallet_balances(wallet_address, raise_on_read_error: false)
    super
  end

  def entry_pda(contest_slug, wallet_address, entry_num)
    super
  end

  def sync_balance(wallet_address, commitment: "confirmed")
    super(wallet_address)
  end

  def seeds_for_entry(entry_num, season_id: nil)
    super(entry_num)
  end

  private

  def land!(wallet, slug, slot, method)
    before_enter&.call
    pda = entry_pda(slug, wallet, slot).first
    raise Solana::Client::RpcError, "#{SIMULATION_FAILED}Allocate: account already in use" if @ledger_accounts[pda]

    failure = fail_next_enter
    self.fail_next_enter = nil
    raise Solana::Client::RpcError, "#{SIMULATION_FAILED}custom program error: 0x1774" if failure == :rejected
    raise Solana::Client::RpcError, "Transaction confirmation timeout" if failure == :unlanded

    yield
    signature = "ledger-sig-#{@sequence += 1}"
    @ledger_accounts[pda] = { "value" => { "lamports" => 1 } }
    @ledger_signatures[pda] = [{ "signature" => signature, "err" => nil }]
    @tickets << { slot: slot, pda: pda, signature: signature, method: method }
    raise Solana::Client::RpcError, "Transaction confirmation timeout" if failure == :lost

    { signature: signature, entry_pda: pda }
  end
end
