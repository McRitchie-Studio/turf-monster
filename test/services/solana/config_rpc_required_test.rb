require "test_helper"

# OPSEC-012's sibling, part two: `SOLANA_RPC_URL` must be REQUIRED in production.
#
# WHY THIS GUARD EXISTS. The constant used to be a bare
# `ENV.fetch("SOLANA_RPC_URL", "https://api.devnet.solana.com")` — the last
# fail-open Solana var, after PROGRAM_ID and NETWORK were closed. The bad
# combination is NETWORK=mainnet-beta with the RPC unset: the mints and the
# program ID resolve to MAINNET values and are then pointed at a DEVNET
# endpoint, so balances read $0.00 and anything submitted lands on the wrong
# cluster against a program that does not exist there.
#
# WHY IT IS NOT REDUNDANT with config/initializers/solana_network_alignment.rb,
# which compares genesis hashes at boot and would catch that exact pair: the
# alignment check is fail-OPEN. It rescues Solana::Client::RpcError and
# CONTINUES BOOT, and the client funnels timeouts, resets and rate limits into
# that one class — so the endpoint misbehaving is precisely what silences the
# check. It also skips entirely on an unknown NETWORK, and wholesale under
# SOLANA_SKIP_NETWORK_CHECK=true. Those three holes are asserted below, because
# they are this guard's premise: if the alignment check ever becomes fail-closed,
# re-read whether this raise still earns its place.
#
# RPC_URL is resolved at LOAD time, so these re-evaluate the real assignment out
# of the real source file in a sandbox rather than asserting the already-loaded
# value — a test that read `Solana::Config::RPC_URL` would only ever describe the
# environment the suite happens to run in.
class Solana::ConfigRpcRequiredTest < ActiveSupport::TestCase
  CONFIG_RB    = Rails.root.join("app/services/solana/config.rb")
  ALIGNMENT_RB = Rails.root.join("config/initializers/solana_network_alignment.rb")
  DEVNET_RPC   = "https://api.devnet.solana.com".freeze

  # Evaluate ONLY the RPC_URL assignment, with Rails.env and ENV controlled.
  # The constant is rewritten to a local so it can be evaluated repeatedly under
  # different environments (Ruby forbids dynamic constant assignment, and a real
  # constant could only ever be set once per process anyway).
  def resolve_rpc_url(env_name, env_value)
    source     = CONFIG_RB.read
    assignment = source[/^    RPC_URL = if Rails\.env\.production\?.*?^    end$/m]
    assert assignment, "the RPC_URL assignment is gone from config.rb — this guard is measuring nothing"

    rails = Struct.new(:env).new(ActiveSupport::StringInquirer.new(env_name))
    env   = env_value.nil? ? {} : { "SOLANA_RPC_URL" => env_value }

    code = assignment.sub(/^    RPC_URL = /, "")
                     .gsub("Rails.env", "rails.env")
                     .gsub("ENV.fetch", "env.fetch")
    eval(code, binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
  end

  test "an UNSET SOLANA_RPC_URL RAISES in production" do
    error = assert_raises(RuntimeError) { resolve_rpc_url("production", nil) }
    assert_match(/SOLANA_RPC_URL required in production/, error.message,
                 "the refusal must name the variable so an operator can act on it")
  end

  test "an explicit SOLANA_RPC_URL is honoured in production" do
    assert_equal "https://example-rpc.invalid/",
                 resolve_rpc_url("production", "https://example-rpc.invalid/")
  end

  test "development still defaults to the devnet RPC when unset" do
    assert_equal DEVNET_RPC, resolve_rpc_url("development", nil)
  end

  test "test still defaults to the devnet RPC when unset" do
    assert_equal DEVNET_RPC, resolve_rpc_url("test", nil)
  end

  test "an explicit SOLANA_RPC_URL still wins outside production" do
    assert_equal "http://127.0.0.1:8899", resolve_rpc_url("development", "http://127.0.0.1:8899")
  end

  # --- the premise: what this raise is additive OVER --------------------------

  test "the alignment guard is fail-OPEN on an unreachable RPC, which is why this raise is additive" do
    source = ALIGNMENT_RB.read

    assert_match(/rescue Solana::Client::RpcError/, source,
                 "if the alignment check stopped swallowing RPC errors it would fail closed — re-read this guard's premise")
    assert_match(/continuing boot/, source,
                 "the rescue must still be the one that CONTINUES boot; a raise there would change this argument")
    assert_match(/skipping alignment check/, source,
                 "an unknown SOLANA_NETWORK still skips the check entirely")
    assert_match(/ENV\["SOLANA_SKIP_NETWORK_CHECK"\] == "true"/, source,
                 "the wholesale escape hatch is still there")
  end

  test "the alignment guard runs AFTER eager load, and this raise runs DURING it" do
    assert_match(/Rails\.application\.config\.after_initialize/, ALIGNMENT_RB.read,
                 "the alignment check is an after_initialize hook — it cannot fire before the constants load")
    assert_match(/^    RPC_URL = if Rails\.env\.production\?/, CONFIG_RB.read,
                 "RPC_URL must stay a load-time constant assignment; moved into a method it would lose the eager-load ordering")
  end
end
