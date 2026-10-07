# frozen_string_literal: true

require "test_helper"

# WHEN MAY A FAILED SERVER-FUNDED CREATE DELETE ITS ROW?
# (contest-create-checks-before-delete)
#
# Contest#create_onchain_with_rollback! used to destroy the row on ANY failure
# of create_onchain!. A failure after the broadcast (a timeout, a 5xx, a rate
# limit that outlived the retries) does not mean the create did not land, and
# the create moves the prize pool: deleting the row there leaves a funded
# on-chain contest that no Rails row points at.
#
# The rule these tests pin: the row is destroyed only when nothing was sent.
# Once the signature was written down, the row is kept `pending` and the chain
# is asked — adopted if the PDA exists, removed only on a chain verdict.
class ContestCreateOnchainRollbackTest < ActiveSupport::TestCase
  # A FakeVault whose server-funded create fails in a chosen way.
  #   before_send: true  — the failure happens AFTER the signature was handed to
  #                        the caller (the real vault's "may have landed" side)
  #   before_send: false — the failure happens before (build error, refused
  #                        simulation): nothing left the server
  class ScriptedVault < FakeVault
    attr_reader :before_send_signatures

    def initialize(raises:, before_send:, **chain)
      super(**chain)
      @raises = raises
      @call_before_send = before_send
      @before_send_signatures = []
    end

    def create_contest_server_funded(contest_slug:, before_send: nil, **_kwargs)
      if @call_before_send
        sig = "SIG-#{contest_slug}"
        before_send&.call(sig)
        @before_send_signatures << sig
      end
      raise @raises
    end
  end

  # The status the HttpError subclass carries. solana-studio's status-first
  # retry raises Solana::Client::HttpError (< RpcError) for a 429/5xx that
  # outlived the retries; turf adopts it at the next lock bump. Until then the
  # constant may not exist, so stand in a subclass of RpcError with the same
  # shape — which is exactly what HttpError is.
  def http_error(status)
    klass = Solana::Client.const_defined?(:HttpError) ? Solana::Client::HttpError : Class.new(Solana::Client::RpcError)
    klass.new("HTTP #{status} from RPC: upstream error", code: status)
  end

  # FakeVault#contest_pda returns ["cpda-<slug>", 254]; identity-encode it so
  # the derived PDA reads "cpda-<slug>", as Contests::PendingReconcilerTest does.
  def with_vault(vault)
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      Solana::Vault.stub :new, vault do
        yield
      end
    end
  end

  def new_contest(slug)
    Contest.create!(
      name: slug.titleize, slug: slug, slate: slates(:one), status: :open,
      contest_type: "small", entry_fee_cents: 19_00, max_entries: 5
    )
  end

  # ── SENT, OUTCOME UNKNOWN: the row is kept ────────────────────────────────

  {
    "the old RpcError (a timeout the gem wrapped)" => -> { Solana::Client::RpcError.new("Network error: Net::ReadTimeout") },
    "the new HttpError (a 503 after the gem's retries)" => -> { http_error(503) },
    "a 429 rate limit after the send" => -> { http_error(429) },
    "Cosign::BroadcastFailed (what the real vault raises)" => -> { Solana::Cosign::BroadcastFailed.new("send may have landed", signature: "SIG-x") },
    "an error type this code has never seen" => -> { Errno::ECONNRESET.new }
  }.each_with_index do |(label, error), i|
    test "a raise after broadcast keeps the row as pending — #{label}" do
      contest = new_contest("uncertain-after-send-#{i}")
      vault = ScriptedVault.new(raises: instance_exec(&error), before_send: true)

      raised = assert_raises(Contest::OnchainCreateUncertain) do
        with_vault(vault) { contest.create_onchain_with_rollback! }
      end

      assert Contest.exists?(contest.id), "a create that may have landed must never delete its row"
      contest.reload
      assert_equal "pending", contest.status
      assert_equal "cpda-#{contest.slug}", contest.onchain_contest_id, "the row names the PDA the chain can be asked about"
      assert_equal "SIG-#{contest.slug}", contest.onchain_tx_signature, "and the signature that was sent"
      assert_nil contest.onchain_reconcile_flagged_at, "an unanswered send is not yet an anomaly"
      assert_match(/Do not create it again/, raised.message)
      assert_empty vault.client.sent_transactions, "the reconcile only reads the chain"
    end
  end

  test "a held row is not re-sent by a manual create_onchain! retry" do
    contest = new_contest("uncertain-no-resend")
    with_vault(ScriptedVault.new(raises: http_error(504), before_send: true)) do
      assert_raises(Contest::OnchainCreateUncertain) { contest.create_onchain_with_rollback! }
    end

    retry_vault = FakeVault.new
    with_vault(retry_vault) { contest.reload.create_onchain! }

    assert_empty retry_vault.server_funded_calls, "a pending row with a PDA must never broadcast a second create"
  end

  # ── REFUSED BEFORE SEND: the row is still deleted ─────────────────────────

  test "a refusal before send still deletes — the simulation refused" do
    contest = new_contest("refused-simulation")
    vault = ScriptedVault.new(raises: Solana::Cosign::PreflightRejected.new("create_contest pre-flight simulation failed"),
                              before_send: false)

    error = assert_raises(RuntimeError) { with_vault(vault) { contest.create_onchain_with_rollback! } }

    assert_not Contest.exists?(contest.id), "nothing left the server, so the row is safe to remove"
    assert_match(/DB row rolled back/, error.message)
  end

  test "a refusal before send still deletes — a build error" do
    contest = new_contest("refused-build")
    vault = ScriptedVault.new(raises: ArgumentError.new("fee array too long"), before_send: false)

    assert_raises(RuntimeError) { with_vault(vault) { contest.create_onchain_with_rollback! } }

    assert_not Contest.exists?(contest.id)
  end

  test "a PreflightRejected is a refusal even if it carries the same RpcError text a send could" do
    contest = new_contest("refused-rpc-text")
    vault = ScriptedVault.new(raises: Solana::Cosign::PreflightRejected.new("simulation could not be run: HTTP 503"),
                              before_send: false)

    assert_raises(RuntimeError) { with_vault(vault) { contest.create_onchain_with_rollback! } }

    assert_not Contest.exists?(contest.id)
  end

  # ── THE CHAIN ANSWERS AT ONCE ─────────────────────────────────────────────

  test "an errored send whose contest IS on chain is adopted, and create returns normally" do
    contest = new_contest("uncertain-landed")
    vault = ScriptedVault.new(raises: http_error(502), before_send: true,
                              account_infos: { "cpda-uncertain-landed" => { "value" => { "data" => ["", "base64"] } } })

    with_vault(vault) { contest.create_onchain_with_rollback! }

    contest.reload
    assert_equal "open", contest.status, "adopted: the status the caller asked for"
    assert_equal "cpda-uncertain-landed", contest.onchain_contest_id
    assert_equal "SIG-uncertain-landed", contest.onchain_tx_signature
    assert contest.accepts_usdt?, "the adopted create funded the USDT slot like any server-funded create"
  end

  test "an errored send the chain says FAILED is removed — a chain verdict, not the exception" do
    contest = new_contest("uncertain-failed")
    vault = ScriptedVault.new(raises: Solana::Client::RpcError.new("Transaction failed"), before_send: true,
                              signature_statuses: { "SIG-uncertain-failed" => { "err" => { "InstructionError" => [0, "Custom"] } } })

    error = assert_raises(RuntimeError) { with_vault(vault) { contest.create_onchain_with_rollback! } }

    assert_not Contest.exists?(contest.id)
    assert_match(/failed on chain/, error.message)
  end

  test "a chain that cannot be read leaves the row held, never deleted" do
    contest = new_contest("uncertain-rpc-down")
    vault = ScriptedVault.new(raises: http_error(503), before_send: true, account_info_raises: true)

    assert_raises(Contest::OnchainCreateUncertain) { with_vault(vault) { contest.create_onchain_with_rollback! } }

    assert_equal "pending", contest.reload.status
  end

  # ── CONTROL: the happy path is unchanged ──────────────────────────────────

  test "CONTROL — a create that succeeds stamps the row and keeps the caller's status" do
    contest = new_contest("create-succeeds")
    vault = FakeVault.new

    with_vault(vault) { contest.create_onchain_with_rollback! }

    contest.reload
    assert_equal "open", contest.status
    assert_equal "cpda-create-succeeds", contest.onchain_contest_id
    assert_equal "fake-create-create-succeeds", contest.onchain_tx_signature
    assert_equal 1, vault.server_funded_calls.size
  end

  test "the callback runs after commit, so a kept row survives the raise" do
    callback = Contest._commit_callbacks.find { |cb| cb.filter == :create_onchain_with_rollback! }
    assert callback, "create_onchain_with_rollback! must be a commit callback: inside the INSERT's " \
                     "transaction a raise rolls the kept row back"
    assert_not Contest._create_callbacks.any? { |cb| cb.filter == :create_onchain_with_rollback! },
               "and not also an after_create"
  end
end
