require "test_helper"

# Money reaches the chain only as integer base units, converted from integer
# cents by Solana::Config.cents_to_base_units. This scan keeps the float path
# from coming back in source:
#
# 1. The float conversions `dollars_to_lamports` and `lamports_to_dollars` are
#    gone, and no file names them again.
# 2. Nothing outside Solana::Config scales by `10**DECIMALS` itself.
# 3. `cents_to_base_units` is never handed float or division arithmetic.
# 4. Float money math (`/ 100.0`, `/ 1_000_000.0`, `fdiv`, `.to_f * 100`,
#    `* 100).to_i`) appears only on the lines pinned below, each of which
#    formats cents for a person to read. The pin is a per-file count, so a new
#    line fails until someone decides it is display; and a pinned line that
#    names a chain sink (base units, lamports, a mint or a settlement) fails
#    whatever the count, because display is the only reason a line is pinned.
#
# Comment lines are skipped; prose may quote the formulas it forbids.
class MoneyIntegerGuardTest < ActiveSupport::TestCase
  ROOTS = %w[app lib config script db].freeze
  EXTENSIONS = %w[.rb .erb .rake .jbuilder].freeze

  REMOVED_API = /\b(dollars_to_lamports|lamports_to_dollars)\b/
  OWN_SCALING = /10\s*\*\*\s*(\d+|(Solana::)?(Config::)?DECIMALS)\b/
  FLOAT_INTO_BASE_UNITS = /cents_to_base_units\([^)]*(\/|\.to_f|\.fdiv|\.round|\d\.\d)/
  FLOAT_MONEY = %r{/\s*100\.0\b|/\s*1_000_000\.0|/\s*1e6\b|\.fdiv\(|\.to_f\s*\*\s*100\b|\*\s*100\)\.to_i}
  CHAIN_SINK = /base_units|lamports|mint_spl|fund_user|transfer_spl|settle|payout:/

  CONFIG = "app/services/solana/config.rb".freeze

  # Display-only float money, by file. Every line formats integer cents as text
  # for a person.
  PINNED = {
    "app/controllers/contests_controller.rb" => 1,               # insufficient-USDC message
    "app/helpers/contests_helper.rb" => 1,                       # payout badge
    "app/jobs/stripe_deposit_job.rb" => 1,                       # ledger description
    "app/jobs/token_purchase_job.rb" => 1,                       # ledger description
    "app/mailers/contest_mailer.rb" => 1,                        # winner email
    "app/models/contest.rb" => 2,                                # entry_fee_dollars, guaranteed_prize_dollars
    "app/models/paypal_purchase.rb" => 1,                        # PayPal price string
    "app/models/transaction_log.rb" => 2,                        # amount_dollars, balance_after_dollars
    "app/models/turf_monster_rules.rb" => 2,                     # rules page example
    "app/services/aeropay/client.rb" => 1,                       # Aeropay price string
    "app/services/paypal/client.rb" => 1,                        # PayPal price string
    "app/views/admin/models/_entries_table.html.erb" => 1,
    "app/views/agents/guide_source.text.erb" => 1,
    "app/views/contests/_final_standings.html.erb" => 1,
    "app/views/contests/_money_line.html.erb" => 1,
    "app/views/contests/_turf_totals_leaderboard.html.erb" => 2,
    "app/views/contests/generator.html.erb" => 1,
    "app/views/contests/new.html.erb" => 5,
    "app/views/faucet/show.html.erb" => 1,
    "app/views/tokens/_pack_button.html.erb" => 1,
    "app/views/transaction_logs/index.html.erb" => 4
  }.freeze

  # Float math on SOL, not money: the network-fee estimate in SOL lamports
  # (Solana::Vault.estimated_fee_sol). Counted like a pin, and exempt from the
  # chain-sink check only because SOL fees are lamports by name.
  SOL_FEE = { "app/services/solana/vault.rb" => 1 }.freeze

  # The lines of each source file, comments dropped, as [path, lineno, text].
  def code_lines
    @code_lines ||= ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, "**", "*")) }
                         .select { |path| File.file?(path) && EXTENSIONS.include?(File.extname(path)) }
                         .flat_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      File.readlines(path).each_with_index.filter_map do |text, i|
        [ relative, i + 1, text ] unless text.lstrip.start_with?("#", "<%#")
      end
    end
  end

  def hits(pattern, except: [])
    code_lines.select { |path, _, text| text.match?(pattern) && !except.include?(path) }
              .map { |path, line, text| "#{path}:#{line}: #{text.strip}" }
  end

  test "the float conversions are named nowhere" do
    assert_empty hits(REMOVED_API)
  end

  test "only Solana::Config scales by a power of ten for base units" do
    assert_empty hits(OWN_SCALING, except: [ CONFIG ])
  end

  test "cents_to_base_units is never handed float arithmetic" do
    assert_empty hits(FLOAT_INTO_BASE_UNITS)
  end

  test "float money math appears only on the pinned display lines" do
    found = code_lines.select { |_, _, text| text.match?(FLOAT_MONEY) }
    counts = found.group_by(&:first).transform_values(&:size)

    pins = PINNED.merge(SOL_FEE)
    unpinned = counts.reject { |path, n| pins.fetch(path, 0) >= n }
    assert_empty unpinned, "new float money math; convert in integer cents, or pin it here if it only formats text"

    stale = pins.reject { |path, n| counts.fetch(path, 0) == n }
    assert_empty stale, "a pinned file now has fewer float lines; lower its pin"

    sinks = found.select { |path, _, text| text.match?(CHAIN_SINK) && !SOL_FEE.key?(path) }.map { |p, l, t| "#{p}:#{l}: #{t.strip}" }
    assert_empty sinks, "a pinned float line feeds the chain"
  end

  test "control: each pattern catches the code it forbids" do
    assert_match REMOVED_API, "Solana::Config.dollars_to_lamports(c / 100.0)"
    assert_match OWN_SCALING, "(dollars * 10**DECIMALS).to_i"
    assert_match OWN_SCALING, "x * 10 ** 6"
    assert_match FLOAT_INTO_BASE_UNITS, "Solana::Config.cents_to_base_units(dollars * 100.0)"
    assert_match FLOAT_INTO_BASE_UNITS, "cents_to_base_units(amount.to_f)"
    assert_match FLOAT_MONEY, "payout: entry.payout_cents / 100.0"
    assert_match FLOAT_MONEY, "(params[:amount].to_f * 100).round"
    assert_match FLOAT_MONEY, "(amount_dollars * 100).to_i"
    assert_match CHAIN_SINK, "payout: Solana::Config.cents_to_base_units(x)"
    refute_match FLOAT_INTO_BASE_UNITS, "Solana::Config.cents_to_base_units(entry.payout_cents)"
  end
end
