require "test_helper"

# [unit] Solana::SignerCeremony — each step's live preconditions as verdicts,
# from plain reads, and the committed mainnet checklist's console links.
class Solana::SignerCeremonyTest < ActiveSupport::TestCase
  XAN   = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  NEW   = "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY".freeze
  ALEX  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  # Stands in for the fresh governance key once minted: the committed file
  # carries a placeholder (UNMINTED:fresh-governance) until then.
  GOV   = "BVQHNwUEo91ePwqPcR6Ro4g9Ejqt3qn3ajKPqJSSTd51".freeze

  def self.minted_steps
    YAML.safe_load_file(Solana::SignerCeremony::PATH)["mainnet-beta"].map do |step|
      step.transform_values { |v| v.is_a?(Array) ? v.map { |k| k == "UNMINTED:fresh-governance" ? GOV : k } : v }
    end
  end

  FUNDED = { balance_sol: 0.4, funded: true }.freeze

  def ceremony(chain_set: [XAN, ALEX, MASON], governance: true, config: true, server: XAN,
               held: [MASON], fee_payer: FUNDED, steps: self.class.minted_steps)
    Solana::SignerCeremony.new(network: "mainnet-beta", chain_set: chain_set, chain_governance: governance,
                               config_governance: config, server: server, server_held: held,
                               fee_payer: fee_payer, steps: steps)
  end

  def step(c, id) = c.steps.find { |s| s[:id] == id }
  def check(s, id) = s[:checks].find { |c| c.id == id }

  test "with every precondition met, the ADD is ready and links the console pre-filled" do
    add = step(ceremony, "add")
    assert_equal "ready", add[:status]
    assert add[:ready]
    assert_equal "/admin/authorities?add=#{NEW}%2C#{GOV}&intent=add", add[:console_path]
    assert check(add, "chain_set").ok
    assert check(add, "window_cosigners").ok
  end

  test "a missing window cosigner blocks the ADD, naming who" do
    add = step(ceremony(held: []), "add")
    assert_equal "blocked", add[:status]
    refute check(add, "window_cosigners").ok
    assert_match(/Not held: Mason/, check(add, "window_cosigners").detail)
  end

  test "each hard precondition blocks on its own" do
    assert_equal "blocked", step(ceremony(server: NEW), "add")[:status], "wrong server identity"
    assert_equal "blocked", step(ceremony(config: false), "add")[:status], "switch disagrees"
    assert_equal "blocked", step(ceremony(fee_payer: { funded: false, balance_sol: 0.0 }), "add")[:status]
    assert_equal "blocked", step(ceremony(chain_set: [XAN, ALEX, GOV]), "add")[:status], "wrong start set"
  end

  test "an open transaction row blocks a console step" do
    PendingTransaction.create!(tx_type: "update_signers", serialized_tx: "x", status: "pending",
                               metadata: "{}", initiator_address: XAN)
    add = step(ceremony, "add")
    refute check(add, "no_open_rows").ok
    assert_equal "blocked", add[:status]
  end

  test "an unread vault says unread, never done and never ready" do
    c = ceremony(chain_set: nil, governance: nil)
    add = step(c, "add")
    assert_equal "unread", add[:status]
    refute add[:ready]
  end

  test "the ADD is done once the chain holds its end set; the flip waits on the server key" do
    c = ceremony(chain_set: [XAN, ALEX, MASON, NEW, GOV].reverse)
    assert_equal "done", step(c, "add")[:status]
    assert_equal "waiting", step(c, "flip")[:status]
    assert_equal "done", step(ceremony(server: NEW), "flip")[:status]
  end

  test "the EVICT is ready on the new server key with the governance key held" do
    evict = step(ceremony(chain_set: [XAN, ALEX, MASON, NEW, GOV], server: NEW, held: [GOV]), "evict")
    assert_equal "ready", evict[:status]
    assert_includes evict[:console_path], "intent=remove"
  end

  test "the committed checklist's slot 5 is unminted, so the ADD and EVICT are blocked and say why" do
    c = Solana::SignerCeremony.new(network: "mainnet-beta", chain_set: [XAN, ALEX, MASON], chain_governance: true,
                                   config_governance: true, server: XAN, server_held: [MASON], fee_payer: FUNDED)
    add = step(c, "add")
    assert_equal "blocked", add[:status]
    refute check(add, "keys_minted").ok
    assert_match(/Fresh governance key \(unminted\)/, check(add, "keys_minted").detail)
    assert_equal "Fresh governance key (unminted)", c.name_for("UNMINTED:fresh-governance")
    refute_includes YAML.safe_load_file(Solana::SignerCeremony::PATH).to_s, "4bKNSqkrKeggSyrds16Ak7rcB4ibvGJ4ZLsKjvQgC3Vk",
                    "4bKN was exposed and is in no VaultState target"
  end

  test "the soft contest check reports without blocking" do
    contest = contests(:one) rescue Contest.first
    skip "no contest fixture" unless contest
    contest.update_columns(starts_at: 2.hours.from_now, status: "open")
    add = step(ceremony, "add")
    refute check(add, "contests").ok
    assert_equal "ready", add[:status]
  end
end
