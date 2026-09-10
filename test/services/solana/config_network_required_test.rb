require "test_helper"

# OPSEC-012's sibling: `SOLANA_NETWORK` must be REQUIRED in production.
#
# WHY THIS GUARD EXISTS. The constant used to be a bare
# `ENV.fetch("SOLANA_NETWORK", "devnet")`, which fails OPEN on absence. A garbage
# value fails CLOSED — it is not "mainnet-beta", so every devnet-only guard
# refuses — but an UNSET var silently resolved to "devnet" on a mainnet app.
#
# WHAT THAT ACTUALLY REACHED — corrected 2026-08-20. This header used to claim
# the unset var would have silently selected the DEVNET MINTS on a mainnet app,
# citing the §8 footgun above the mint constants. The MECHANISM is real —
# USDC_MINT / USDT_MINT key their DEFAULTS on NETWORK — but that outcome was NOT
# REACHABLE: `turf-monster-mainnet` sets SOLANA_USDC_MINT and SOLANA_USDT_MINT
# explicitly, and the env override always wins, so it needed THREE unset vars,
# not one. The claim was asserted without reading the live config that disproves
# it, and is corrected rather than dropped so nobody cites it as history.
#
# The honest case is IDL_PATH and LEGIBILITY. NETWORK also keys IDL_PATH, so an
# unset var on the mainnet app selects the DEVNET IDL, whose SHA256 is not in
# that app's EXPECTED_IDL_HASH. The boot is refused either way — by the OPSEC-014
# guard as an opaque hash diff, or by the OPSEC-039 alignment guard as a genesis
# diff whose remediation line names the WRONG variable. Both are
# `after_initialize`; this raise fires during EAGER LOAD, ahead of both, and
# names the variable. Behind them, `Solana::Config.devnet?` reads this same
# constant, so the OPSEC-020 fund guards are what an unset var re-arms once the
# IDL guard is bypassed.
#
# PRESENT-BUT-EMPTY — added 2026-09-06 by empty-solana-network-fails-open. The
# guard this file shipped with pinned the ABSENCE case only, and the expression
# it pinned had a second hole of the same family: the BLOCK form of `ENV.fetch`
# fires only when the key is ABSENT, so a key present with an empty value
# yielded "" and skipped the raise entirely. One `heroku config:set
# SOLANA_NETWORK=` was enough. The fix is `.presence`, which folds nil, "", and
# whitespace-only into one refusal.
#
# THE THREE STATES ARE THREE TESTS, ON PURPOSE. Unset, empty, and whitespace-only
# are asserted separately and never as one parameterised case, so no state can
# pass on another's strength — and the UNSET test below is untouched from the
# original guard, which makes it the regression proof that the empty fix did not
# widen or relax what was already pinned.
#
# NETWORK is resolved at LOAD time, so these re-evaluate the real assignment out
# of the real source file in a sandbox rather than asserting the already-loaded
# value — a test that read `Solana::Config::NETWORK` would only ever describe the
# environment the suite happens to run in. That sandbox is also why this property
# needs NO constant surgery: `remove_const` / `const_set` (which three other test
# files in this repo use) replaces the VALUE and never re-runs the ASSIGNMENT, so
# it cannot observe a raise that only the assignment can produce.
class Solana::ConfigNetworkRequiredTest < ActiveSupport::TestCase
  CONFIG_RB = Rails.root.join("app/services/solana/config.rb")

  # Evaluate ONLY the NETWORK assignment, with Rails.env and ENV controlled.
  # The constant is rewritten to a local so it can be evaluated repeatedly under
  # different environments (Ruby forbids dynamic constant assignment, and a real
  # constant could only ever be set once per process anyway).
  #
  # The ENV rewrite is by WORD, not by call shape. It used to rewrite the literal
  # string "ENV.fetch", which silently became a no-op the moment the assignment
  # switched to `ENV["SOLANA_NETWORK"].presence` — and a sandbox that reads the
  # REAL process ENV describes the machine running the suite, not the property.
  # The refute below is the vacuity proof for that rewrite: if any bare `ENV`
  # survives, this harness is measuring the wrong environment and says so.
  def resolve_network(env_name, env_value)
    source     = CONFIG_RB.read
    assignment = source[/^    NETWORK = if Rails\.env\.production\?.*?^    end$/m]
    assert assignment, "the NETWORK assignment is gone from config.rb — this guard is measuring nothing"

    rails = Struct.new(:env).new(ActiveSupport::StringInquirer.new(env_name))
    env   = env_value.nil? ? {} : { "SOLANA_NETWORK" => env_value }

    code = assignment.sub(/^    NETWORK = /, "")
                     .gsub("Rails.env", "rails.env")
                     .gsub(/\bENV\b/, "env")
    refute_match(/\bENV\b/, code,
                 "a bare ENV survived the rewrite — this sandbox would read the real " \
                 "process environment and prove nothing about the assignment")

    eval(code, binding, __FILE__, __LINE__) # rubocop:disable Security/Eval
  end

  test "an UNSET SOLANA_NETWORK RAISES in production" do
    error = assert_raises(RuntimeError) { resolve_network("production", nil) }
    assert_match(/SOLANA_NETWORK required in production/, error.message,
                 "the refusal must name the variable so an operator can act on it")
  end

  # THE NEW CASE. Distinct from the unset test above: the key is PRESENT here, so
  # `ENV.fetch(k) { raise }` would have returned "" and booted a mainnet app onto
  # the devnet Squad, the devnet IDL, and a NETWORK that answers "no" to both
  # `devnet?` and `mainnet?`.
  test "a PRESENT-BUT-EMPTY SOLANA_NETWORK RAISES in production" do
    error = assert_raises(RuntimeError) { resolve_network("production", "") }
    assert_match(/SOLANA_NETWORK required in production/, error.message,
                 "an empty value must refuse exactly as an absent one does")
  end

  # Kept SEPARATE from the empty case rather than folded in with it: `.presence`
  # makes them one code path today, but they are two different operator mistakes
  # (`SOLANA_NETWORK=` versus a value that got quoted down to spaces), and a
  # single test would let a fix that handled only `.empty?` pass.
  test "a WHITESPACE-ONLY SOLANA_NETWORK RAISES in production" do
    error = assert_raises(RuntimeError) { resolve_network("production", "   ") }
    assert_match(/SOLANA_NETWORK required in production/, error.message,
                 "whitespace is not a cluster name — it must refuse like empty and unset")
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

  # The non-production half of the same fix, and the one behaviour this change
  # alters outside production: an empty local var used to resolve to "" — a value
  # that is neither cluster, so `devnet?` went false and the dev funding tools
  # refused on a devnet box. It now lands on the same default as unset.
  test "development falls back to devnet when SET-BUT-EMPTY" do
    assert_equal "devnet", resolve_network("development", "")
  end

  # The REACHABLE consequence. IDL_PATH has no env override, so NETWORK alone
  # decides which IDL a mainnet app verifies against — this is the coupling that
  # made the fail-open matter, not the mint defaults.
  test "IDL_PATH is keyed on NETWORK with no env override, which is why the fail-open mattered" do
    source = CONFIG_RB.read

    assert_match(/IDL_PATH = if NETWORK == "mainnet-beta"/, source,
                 "if IDL_PATH stops keying on NETWORK, re-read this guard's premise")
    assert_no_match(/IDL_PATH = ENV\.fetch/, source,
                    "an env override on IDL_PATH would give operators a way around this coupling")
  end

  # The mint defaults key on NETWORK too, but the env override always wins and
  # the mainnet app sets both explicitly (turf-monster-qa leaves them unset and
  # is devnet, which is what the default gives it) — so this is a LATENT
  # coupling, not the reachable one. Kept as a guard on the corrected claim: if a mint
  # default ever stops being overridable, the §8 story changes.
  test "the mint defaults key on NETWORK, but an explicit mint always wins" do
    source = CONFIG_RB.read

    assert_match(/USDC_MINT = ENV\.fetch\("SOLANA_USDC_MINT"\) do/, source,
                 "the env override is what made the devnet-mints outcome unreachable in practice")
    assert_match(/NETWORK == "mainnet-beta" \? MAINNET_USDC_MINT : DEVNET_USDC_MINT/, source,
                 "the DEFAULT is network-keyed; the override is checked first")
  end
end
