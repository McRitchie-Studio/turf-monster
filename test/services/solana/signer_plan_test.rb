require "test_helper"

# [unit] Solana::SignerPlan — the derivation matrix per shape and intent.
#
# Every case asserts WHO signs and HOW MANY Phantom prompts, because those are
# the two facts the 2026-10-11 console got wrong by hand: it asked Phantom for
# the server's own key, and it let the lead and cosigner be swapped.
class Solana::SignerPlanTest < ActiveSupport::TestCase
  XAN    = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze # production server
  NEW    = "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY".freeze
  ALEX   = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  ALEX2  = "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf".freeze
  ALEX3  = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  GOV    = "4bKNSqkrKeggSyrds16Ak7rcB4ibvGJ4ZLsKjvQgC3Vk".freeze
  MASON  = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  QA     = "2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9".freeze
  UNKNOWN = "BVQHNwUEo91ePwqPcR6Ro4g9Ejqt3qn3ajKPqJSSTd51".freeze

  ROSTER = Solana::SignerRoster.new("keys" => [
    { "address" => XAN, "name" => "Xan", "holder" => "agent", "signs_in" => "server", "clusters" => ["mainnet-beta"] },
    { "address" => NEW, "name" => "New server", "holder" => "agent", "signs_in" => "server", "clusters" => ["mainnet-beta"] },
    { "address" => ALEX, "name" => "Alex 1", "holder" => "alex", "signs_in" => "phantom", "clusters" => ["mainnet-beta"] },
    { "address" => ALEX2, "name" => "Alex 2", "holder" => "alex", "signs_in" => "phantom", "clusters" => %w[mainnet-beta devnet] },
    { "address" => ALEX3, "name" => "Alex 3", "holder" => "alex", "signs_in" => "phantom", "clusters" => %w[mainnet-beta devnet] },
    { "address" => GOV, "name" => "Governance", "holder" => "agent", "signs_in" => "server", "clusters" => ["mainnet-beta"] },
    { "address" => MASON, "name" => "Mason", "holder" => "agent", "signs_in" => "server", "clusters" => ["mainnet-beta"] },
    { "address" => QA, "name" => "QA server", "holder" => "agent", "signs_in" => "server", "clusters" => ["devnet"] }
  ])

  def planner(current:, governance: true, server: XAN, held: [], network: "mainnet-beta",
              required: governance ? 3 : 2, connected: nil, max_live: governance ? 3 : nil)
    Solana::SignerPlan.new(network: network, governance: governance, current: current, required: required,
                           server: server, server_held: held, roster: ROSTER, connected: connected,
                           max_live_threshold: max_live)
  end

  def refusal(planner, **args)
    planner.plan!(**args)
    flunk "expected a refusal"
  rescue Solana::SignerPlan::Refusal => e
    e
  end

  # ── v0.26, the mainnet ceremony ───────────────────────────────────────────

  test "v0.26 ADD: server leads, the window cosigner signs on the server, Alex signs once" do
    plan = planner(current: [XAN, ALEX, MASON], held: [MASON])
             .plan!(intent: "add", add: [NEW, GOV])

    assert_equal [XAN, ALEX, MASON, NEW, GOV], plan[:proposed]
    assert_equal [XAN, MASON, ALEX], plan[:authorizers]
    assert plan[:server_leads]
    assert_equal [MASON], plan[:server_held]
    assert_equal [ALEX], plan[:phantom_queue]
    assert_equal 1, plan[:prompt_count]
    assert_equal "The server signs for itself as 8K81…aRYd and for CytJ…WjrR. " \
                 "You sign once in Phantom as 7ZDJ…9Tcr.", plan[:sentence]
  end

  test "v0.26 ADD without the window cosigner is refused, naming the key Steffon must set" do
    error = refusal(planner(current: [XAN, ALEX, MASON]), intent: "add", add: [NEW, GOV])
    assert_equal "not_enough_signers", error.code
    assert_includes error.message, "CytJ…WjrR"
    assert_includes error.message, "SOLANA_COSIGNER_KEYS"
  end

  test "v0.26 EVICT as a remove with adds: new server leads, governance key held, Alex once" do
    plan = planner(current: [XAN, ALEX, MASON, NEW, GOV], server: NEW, held: [GOV])
             .plan!(intent: "remove", remove: [XAN, MASON], add: [ALEX2, ALEX3])

    assert_equal [ALEX, NEW, GOV, ALEX2, ALEX3], plan[:proposed]
    assert_equal [NEW, GOV, ALEX], plan[:authorizers]
    assert_equal [ALEX], plan[:phantom_queue]
    assert_equal [XAN, MASON], plan[:evicted]
  end

  test "v0.26 with no server-held key asks for two Phantom accounts, connected one first" do
    plan = planner(current: [NEW, ALEX, ALEX2, ALEX3, GOV], server: NEW, connected: ALEX2)
             .plan!(intent: "replace", remove: [GOV], add: [MASON])

    assert_equal [NEW, ALEX2, ALEX], plan[:authorizers]
    assert_equal [ALEX2, ALEX], plan[:phantom_queue]
    assert_equal 2, plan[:prompt_count]
    assert_match(/You sign twice: first as 9gAC…vHXf, then switch Phantom to 7ZDJ…9Tcr/, plan[:sentence])
  end

  # The rotation ptx-432 and ptx-433 lost to the blockhash (2026-10-14): two
  # prompts and an account switch. On the console nonce it has no clock, and
  # the sentence says so; without one, it keeps the honest warning.
  test "the two-prompt rotation promises no time limit only when the console nonce is ready" do
    args = { current: [NEW, ALEX, ALEX2, ALEX3, GOV], server: NEW, connected: ALEX2 }
    draft = { intent: "replace", remove: [GOV], add: [MASON] }
    timed = planner(**args).plan!(**draft)
    untimed = Solana::SignerPlan.new(network: "mainnet-beta", governance: true, current: args[:current], required: 3,
                                     server: NEW, roster: ROSTER, connected: ALEX2, max_live_threshold: 3,
                                     nonce_ready: true).plan!(**draft)

    assert_match(/about 45 seconds/, timed[:sentence])
    refute timed[:no_time_limit]
    assert_match(/no time limit/, untimed[:sentence])
    assert untimed[:no_time_limit]
  end

  test "agent keys never fill every slot: the last signature is always Alex's" do
    plan = planner(current: [XAN, ALEX, MASON, GOV], held: [MASON, GOV])
             .plan!(intent: "add", add: [NEW])
    assert_equal [XAN, MASON, ALEX], plan[:authorizers]
    assert_equal 1, plan[:prompt_count]
  end

  test "a change that keeps none of Alex's accounts is refused" do
    error = refusal(planner(current: [XAN, ALEX, MASON], held: [MASON]),
                    intent: "replace", remove: [ALEX], add: [NEW])
    assert_equal "no_human_signer", error.code
  end

  test "removing the server's own key on mainnet is refused as operator-led" do
    error = refusal(planner(current: [XAN, ALEX, ALEX2, ALEX3, GOV]),
                    intent: "remove", remove: [XAN])
    assert_equal "operator_led_mainnet", error.code
  end

  test "on devnet an operator-led rotation is derived, every signer in Phantom, lead first" do
    plan = planner(current: [QA, ALEX, ALEX2, ALEX3, GOV], network: "devnet", server: QA, connected: ALEX3)
             .plan!(intent: "remove", remove: [QA, GOV])
    refute plan[:server_leads]
    assert_equal [ALEX3, ALEX, ALEX2], plan[:authorizers]
    assert_equal plan[:authorizers], plan[:phantom_queue]
    assert_equal ALEX3, plan[:lead_signer]
  end

  test "remove below the live threshold is not offered and is refused" do
    p = planner(current: [XAN, ALEX, MASON])
    assert_match(/cannot go below 3/, p.rules[:intents]["remove"])
    assert_equal "intent_not_allowed", refusal(p, intent: "remove", remove: [MASON]).code
  end

  # ── v0.25 ─────────────────────────────────────────────────────────────────

  test "v0.25 replace: two signers, the server and Alex, both stay" do
    plan = planner(current: [XAN, ALEX, MASON], governance: false)
             .plan!(intent: "replace", remove: [MASON], add: [QA])
    assert_equal [XAN, ALEX, QA], plan[:proposed]
    assert_equal [XAN, ALEX], plan[:authorizers]
    assert_equal [ALEX], plan[:phantom_queue]
    assert_equal "v0.25", plan[:shape]
  end

  test "v0.25 prefers Alex over a held key, so the rotation is never agent-only" do
    plan = planner(current: [XAN, ALEX, MASON], governance: false, held: [MASON])
             .plan!(intent: "replace", remove: [MASON], add: [QA])
    assert_equal [XAN, ALEX], plan[:authorizers]
  end

  test "v0.25 offers neither add nor remove, and says why" do
    rules = planner(current: [XAN, ALEX, MASON], governance: false).rules
    assert_nil rules[:intents]["replace"]
    assert_match(/no empty slot/, rules[:intents]["add"])
    assert_match(/only be replaced/, rules[:intents]["remove"])
    assert_equal 3, rules[:max_slots]
  end

  # ── address refusals, none of which writes anything ───────────────────────

  test "a trailing full stop is refused as a bad address, echoing the value" do
    error = refusal(planner(current: [XAN, ALEX, MASON], held: [MASON]), intent: "add", add: ["#{NEW}."])
    assert_equal "bad_address", error.code
    assert_includes error.message, "#{NEW}."
  end

  test "a value long enough to be a secret is described, never echoed" do
    secret = Solana::Keypair.encode_base58(Solana::Keypair.generate.to_bytes)
    error = refusal(planner(current: [XAN, ALEX, MASON], held: [MASON]), intent: "add", add: [secret])
    assert_equal "bad_address", error.code
    refute_includes error.message, secret
  end

  test "an off-curve key (a program-derived address) is refused: nothing can ever sign for it" do
    pda = Solana::Keypair.encode_base58(Solana::Transaction.find_pda(["vault_state".b],
                                                                     Solana::Keypair.decode_base58(XAN)).first)
    error = refusal(planner(current: [XAN, ALEX, MASON], held: [MASON]), intent: "add", add: [pda],
                    confirm_unknown: [pda])
    assert_equal "off_curve", error.code
  end

  test "the zero key is refused" do
    error = refusal(planner(current: [XAN, ALEX, MASON], held: [MASON]), intent: "add",
                    add: [Solana::SignerRotation::EMPTY])
    assert_equal "zero_key", error.code
  end

  test "an already-seated key is refused" do
    error = refusal(planner(current: [XAN, ALEX, MASON], governance: false),
                    intent: "replace", remove: [MASON], add: [ALEX])
    assert_equal "already_seated", error.code
  end

  test "removing a key that is not seated is refused" do
    error = refusal(planner(current: [XAN, ALEX, MASON], governance: false),
                    intent: "replace", remove: [NEW], add: [QA])
    assert_equal "not_seated", error.code
  end

  test "an unknown key needs confirming, and confirming it is enough" do
    p = planner(current: [XAN, ALEX, MASON], governance: false)
    assert_equal "unknown_key_unconfirmed", refusal(p, intent: "replace", remove: [MASON], add: [UNKNOWN]).code

    plan = p.plan!(intent: "replace", remove: [MASON], add: [UNKNOWN], confirm_unknown: [UNKNOWN])
    assert plan[:labels][UNKNOWN][:unknown]
    assert_equal "Unknown key", plan[:labels][UNKNOWN][:name]
  end

  test "a chain-rule refusal carries the turf-vault code" do
    # A live action needs 4 signatures; removing two of five leaves 3.
    p = planner(current: [XAN, ALEX, MASON, ALEX2, ALEX3], held: [MASON], max_live: 4)
    error = refusal(p, intent: "remove", remove: [ALEX2, ALEX3])
    assert_equal "chain_rule", error.code
    assert_equal 6052, error.chain_code
    assert_equal "SignerSetTooSmall", error.error_name
  end

  test "a full set offers no add, and a replace must pair its keys" do
    p = planner(current: [XAN, ALEX, MASON, ALEX2, ALEX3], held: [MASON])
    assert_match(/All 5 slots are filled/, p.rules[:intents]["add"])
    assert_equal "replace_needs_pairs", refusal(p, intent: "replace", remove: [ALEX2, ALEX3], add: [NEW]).code
  end

  test "the plan labels every key it names, unknown and server-held included" do
    plan = planner(current: [XAN, ALEX, MASON], held: [MASON], connected: ALEX)
             .plan!(intent: "add", add: [NEW])
    assert plan[:labels][XAN][:server]
    assert plan[:labels][MASON][:server_held]
    assert plan[:labels][ALEX][:connected]
    assert_equal "Alex 1", plan[:labels][ALEX][:name]
  end

  test "the rules object carries every shape fact the browser needs" do
    rules = planner(current: [XAN, ALEX, MASON], held: [MASON]).rules
    assert_equal "v0.26", rules[:shape]
    assert_equal 5, rules[:max_slots]
    assert_equal 3, rules[:required]
    assert rules[:server_seated]
    assert_equal [MASON], rules[:server_held]
    refute rules[:operator_led_allowed]
  end
end
