require "test_helper"

# OPSEC-012's sibling: `SOLANA_NETWORK` must be REQUIRED in production.
#
# WHY THIS GUARD EXISTS. The constant used to be a bare
# `ENV.fetch("SOLANA_NETWORK", "devnet")`, which fails OPEN on absence. A garbage
# value fails CLOSED — it is not "mainnet-beta", so every devnet-only guard
# refuses — but an UNSET var silently resolved to "devnet" on a mainnet app.
# That is the door into the §8 silent-default footgun documented above the mint
# constants: USDC_MINT / USDT_MINT key their DEFAULTS on NETWORK, so a mainnet
# app missing this var reads balances against the DEVNET mints and derives
# op-rev PDAs against a mint that does not exist on mainnet. Network-keyed
# defaults cannot protect anyone when the key they are keyed on is itself
# defaulted. It also left the OPSEC-020 fund guards resting on one check, since
# `Solana::Config.devnet?` reads this same constant.
#
# NETWORK is resolved at LOAD time, so these re-evaluate the real assignment out
# of the real source file in a sandbox rather than asserting the already-loaded
# value — a test that read `Solana::Config::NETWORK` would only ever describe the
# environment the suite happens to run in.
class Solana::ConfigNetworkRequiredTest < ActiveSupport::TestCase
  CONFIG_RB = Rails.root.join("app/services/solana/config.rb")

  # Evaluate ONLY the NETWORK assignment, with Rails.env and ENV controlled.
  # The constant is rewritten to a local so it can be evaluated repeatedly under
  # different environments (Ruby forbids dynamic constant assignment, and a real
  # constant could only ever be set once per process anyway).
  def resolve_network(env_name, env_value)
    source     = CONFIG_RB.read
    assignment = source[/^    NETWORK = if Rails\.env\.production\?.*?^    end$/m]
    assert assignment, "the NETWORK assignment is gone from config.rb — this guard is measuring nothing"

    rails = Struct.new(:env).new(ActiveSupport::StringInquirer.new(env_name))
    env   = env_value.nil? ? {} : { "SOLANA_NETWORK" => env_value }

    code = assignment.sub(/^    NETWORK = /, "")
                     .gsub("Rails.env", "rails.env")
                     .gsub("ENV.fetch", "env.fetch")
    eval(code, binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
  end

  test "an UNSET SOLANA_NETWORK RAISES in production" do
    error = assert_raises(RuntimeError) { resolve_network("production", nil) }
    assert_match(/SOLANA_NETWORK required in production/, error.message,
                 "the refusal must name the variable so an operator can act on it")
  end

  test "an explicit SOLANA_NETWORK is honoured in production" do
    assert_equal "mainnet-beta", resolve_network("production", "mainnet-beta")
  end

  test "development still defaults to devnet when unset" do
    assert_equal "devnet", resolve_network("development", nil)
  end

  test "test still defaults to devnet when unset" do
    assert_equal "devnet", resolve_network("test", nil)
  end

  test "the mint defaults are keyed on NETWORK, which is why the fail-open mattered" do
    source = CONFIG_RB.read

    assert_match(/USDC_MINT = ENV\.fetch\("SOLANA_USDC_MINT"\)/, source)
    assert_match(/NETWORK == "mainnet-beta" \? MAINNET_USDC_MINT : DEVNET_USDC_MINT/, source,
                 "if the mint default stops keying on NETWORK, re-read this guard's premise")
  end
end
