require "test_helper"
require "minitest/mock"

class FaucetControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam)          # has web3_solana_address (phantom wallet)
    @user_no_wallet = users(:alex) # no solana wallet
  end

  # --- show ---

  test "show is accessible without login" do
    get faucet_path
    assert_response :success
    assert_select "h1", /Devnet Faucet/
  end

  test "show displays claim button when logged in with wallet" do
    log_in_as(@user)
    get faucet_path
    assert_response :success
    assert_select "button", /Claim/
  end

  test "show displays connect wallet CTA when logged in without wallet" do
    log_in_as(@user_no_wallet)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", account_path
  end

  test "show displays sign-in CTA when not logged in" do
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", signin_path
  end

  # --- claim ---

  test "claim requires login" do
    post faucet_path, params: { amount: 50 }, as: :json
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
  end

  test "claim mints USDC and creates transaction log" do
    log_in_as(@user)

    mock_vault = Minitest::Mock.new
    mock_vault.expect :ensure_ata, { ata: "fake_ata", created: false, signature: nil }, [String], mint: String
    mock_vault.expect :mint_spl, { signature: "fake_tx_sig" }, [Integer], mint: String, to: String

    Solana::Vault.stub :new, mock_vault do
      assert_difference "TransactionLog.count", 1 do
        post faucet_path, params: { amount: 50 }, as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "fake_tx_sig", json["tx"]

    txn = TransactionLog.last
    assert_equal "faucet", txn.transaction_type
    assert_equal 50_00, txn.amount_cents
    assert_equal "credit", txn.direction
    assert_equal @user, txn.user
  end

  test "claim rejects zero amount" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: 0 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end

  test "claim rejects amount over 500" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: 501 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end

  test "claim rejects negative amount" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: -10 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end

  # --- OPSEC-020 production guard ---
  #
  # Regression: QA Heroku apps set no RAILS_ENV, so they boot as Rails
  # production. The guard used to ask Rails.env.production? directly, which
  # answered TRUE on QA and refused every claim there — observed live on
  # qa.turfmonster.media as POST /faucet -> 422 "Faucet is production-disabled",
  # with zero faucet TransactionLog rows in the app's whole history. The guard
  # now asks AppFlags.live_production?, which QA_ENV=true excludes.
  #
  # The whole point of this pair is that Rails.env is production in BOTH cases
  # and only QA_ENV differs — a test that just ran in the test env would pass
  # against the old code too.

  # Every var Solana::Config REQUIRES in production is set alongside the
  # Rails.env stub, because a production app cannot BOOT without them: the
  # constants raise on absence (OPSEC-012 and siblings — SOLANA_PROGRAM_ID,
  # SOLANA_NETWORK, and now SOLANA_RPC_URL). Config resolves them at LOAD time,
  # so a request that loads it lazily inside this block would raise; without
  # these the simulation models a production app that cannot exist.
  #
  # This is the trap that hides in CI: config/environments/test.rb sets
  # `eager_load = ENV["CI"].present?`, so in CI everything is already loaded at
  # boot and a missing var here is INVISIBLE, while locally (lazy autoload) it
  # raises. The test below asserts this list against config.rb's own source, so
  # a fourth required var cannot land without this helper learning about it.
  #
  # Values reproduce the live QA app (SOLANA_NETWORK=devnet), except the RPC,
  # which is the hermetic black hole CI pins for e2e — nothing here should reach
  # a network, and only the var's PRESENCE is load-bearing.
  PRODUCTION_ENV_STUB = {
    "SOLANA_NETWORK"    => "devnet",
    "SOLANA_RPC_URL"    => "http://127.0.0.1:9",
    "SOLANA_PROGRAM_ID" => "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ"
  }.freeze

  def with_production_env
    originals = PRODUCTION_ENV_STUB.keys.to_h { |var| [var, ENV[var]] }
    PRODUCTION_ENV_STUB.each { |var, value| ENV[var] = value }
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) { yield }
  ensure
    originals&.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
  end

  test "with_production_env sets every var Solana::Config requires in production" do
    source   = Rails.root.join("app/services/solana/config.rb").read
    required = source.scan(/ENV\.fetch\("(\w+)"\) \{ raise/).flatten

    assert_operator required.size, :>=, 3,
                    "expected the production-required env vars to still be declared as raising ENV.fetch calls in config.rb"

    # The ambient env must be CLEARED first, or this measures the shell instead
    # of the helper. Measured: dotenv loads .env in dev/test and it sets
    # SOLANA_RPC_URL and SOLANA_PROGRAM_ID, so deleting a var from
    # PRODUCTION_ENV_STUB left this test GREEN locally until the delete below was
    # added. CI's unit job (.github/workflows/ci.yml) exports only
    # SOLANA_ADMIN_KEY, so the two environments disagree about what is ambient —
    # which is exactly why this test controls it rather than trusting it.
    before = required.to_h { |var| [var, ENV.delete(var)] }

    with_production_env do
      required.each do |var|
        assert ENV[var].present?,
               "#{var} raises when unset in production but with_production_env does not set it — " \
               "this simulation models a production app that cannot boot (add it to PRODUCTION_ENV_STUB)"
      end
    end

    required.each do |var|
      assert_nil ENV[var],
                 "with_production_env must restore #{var} to what it found — a leak would silently re-point the rest of the suite"
    end
  ensure
    before&.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
  end

  def with_qa_env(value)
    original = ENV["QA_ENV"]
    value.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = value
    yield
  ensure
    original.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = original
  end

  test "claim is refused on live production (Rails production, QA_ENV unset)" do
    log_in_as(@user)

    with_production_env do
      with_qa_env(nil) do
        assert_no_difference "TransactionLog.count" do
          post faucet_path, params: { amount: 50 }, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_equal "Faucet is production-disabled", json["error"]
  end

  test "claim mints on a QA app (Rails production, QA_ENV=true)" do
    log_in_as(@user)

    mock_vault = Minitest::Mock.new
    mock_vault.expect :ensure_ata, { ata: "fake_ata", created: false, signature: nil }, [String], mint: String
    mock_vault.expect :mint_spl, { signature: "qa_tx_sig" }, [Integer], mint: String, to: String

    with_production_env do
      with_qa_env("true") do
        Solana::Vault.stub :new, mock_vault do
          assert_difference "TransactionLog.count", 1 do
            post faucet_path, params: { amount: 50 }, as: :json
          end
        end
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "qa_tx_sig", json["tx"]
    assert_equal "faucet", TransactionLog.last.transaction_type
  end
end
