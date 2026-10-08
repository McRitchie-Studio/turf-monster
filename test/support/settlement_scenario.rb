# A graded on-chain contest whose settle transaction was cosigned and
# broadcast, plus a chain that answers what a test seeds. Shared by the
# settlement reconciler, sweep and controller tests.
#
# The landed transaction is a real getTransaction shape, so Solana::TxVerifier
# runs unstubbed: signer 0 is a stand-in for the server key, signer 1 the vault
# cosigner, then the contest account (writable) and the program.
module SettlementScenario
  SERVER_KEY = "F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ".freeze # stand-in only

  # The slice of Solana::Vault the reconciler uses.
  class Chain
    attr_reader :client

    # `contest_status:` is what the contest account reads; nil is a closed account.
    def initialize(statuses: {}, transactions: {}, status_raises: nil, contest_status: "Settled")
      @client = FakeSolanaClient.new(statuses, transactions: transactions, status_raises: status_raises)
      @contest_status = contest_status
    end

    def contest_pda(slug) = ["cpda-#{slug}", 254]

    def read_contest(_slug) = @contest_status && { status: @contest_status }
  end

  def settlement_contest(name: "Settlement sweep")
    contest = Contest.create!(name: "#{name} #{SecureRandom.hex(3)}", slate: slates(:one),
                              rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                              user: users(:alex), status: "open", max_entries: 29)
    contest.update_columns(onchain_contest_id: EnteredOnchain.random_wallet)
    contest
  end

  def settlement_entry(contest, score:)
    user = User.create!(email: "settle_#{SecureRandom.hex(4)}@example.com",
                        web3_solana_address: EnteredOnchain.random_wallet)
    Entry.create!(user: user, contest: contest, status: "active", score: score,
                  **EnteredOnchain.attrs(contest, user.web3_solana_address))
  end

  # Grades through the real Contest#grade!; only the settle build is stood in.
  def grade_onchain!(contest)
    builder = Object.new
    builder.define_singleton_method(:build_settle_contest) do |slug, _winners, **_kw|
      { serialized_tx: Base64.strict_encode64("settle-#{slug}") }
    end
    Solana::Vault.stub(:new, builder) do
      contest.stub(:score_entries!, nil) { contest.grade! }
    end
    contest.reload
  end

  # The settle row as #broadcast leaves it: claimed under `signature`.
  def broadcast_settlement!(contest, signature:, broadcast_at: 2.minutes.ago)
    tx = contest.settlement_transaction
    raise "no settle transaction queued" unless tx&.claim_for_broadcast!(signature)

    tx.update_columns(broadcast_at: broadcast_at)
    tx
  end

  def landed_status = { "err" => nil, "confirmationStatus" => "finalized" }

  def failed_status(code = 6047)
    { "err" => { "InstructionError" => [0, { "Custom" => code }] }, "confirmationStatus" => "finalized" }
  end

  # A landed settle_contest on the vault program that writes `account`.
  def settle_transaction_info(account:, instruction: "settle_contest", cosigner: Solana::Config::MULTISIG_COSIGNER)
    {
      "meta" => { "err" => nil },
      "transaction" => {
        "message" => {
          "header" => { "numRequiredSignatures" => 2, "numReadonlySignedAccounts" => 0,
                        "numReadonlyUnsignedAccounts" => 1 },
          "accountKeys" => [SERVER_KEY, cosigner, account, Solana::Config::PROGRAM_ID],
          "instructions" => [{
            "programIdIndex" => 3, "accounts" => [0, 1, 2],
            "data" => Solana::Keypair.encode_base58(Solana::Transaction.anchor_discriminator(instruction))
          }]
        }
      }
    }
  end
end
