require "test_helper"

# Every SERVER-SIDE Solana RPC client must be built through `Solana::Config`.
#
# THE BUG (route-solana-clients-through-config; Jasper's N5 finding from the
# Carl+Jasper review of require-solana-rpc-in-production). Six call sites wrote
# a bare `Solana::Client.new`, so the GEM resolved the endpoint instead of this
# app:
#
#   app/controllers/wallets_controller.rb              #airdrop
#   app/controllers/cdp/offramp_sends_controller.rb    #verify_reported_signature!
#   app/services/cdp/offramp_destination.rb            .resolve + #initialize
#   app/services/solana/vault.rb                       #initialize
#   app/services/solana/tx_verifier.rb                 .verify!
#
# `Solana::Client#initialize` falls back to `ENV.fetch("SOLANA_RPC_URL",
# DEFAULT_RPC_URL)` where `DEFAULT_RPC_URL` is the public DEVNET endpoint —
# it FAILS OPEN. `Solana::Config::RPC_URL` FAILS CLOSED (OPSEC-012 raises when
# the var is unset in production). A path that never asks Config gets the
# fail-open behaviour on a mainnet app, and sits outside the public/credentialed
# split and `redact_rpc_url` that PR 390 made Config's job.
#
# WHY A SOURCE SCAN. PR 390 left a standing ban on `Config::RPC_URL` appearing
# in `.erb` / `app/javascript` (rpc_credential_not_in_browser_test.rb). That ban
# is blind to Ruby, and nothing at RUNTIME can stop a seventh bare
# `Solana::Client.new` — the constructor lives in the gem and this app must not
# monkey-patch an installed gem. So the invariant is enforced where it is
# written: the source tree.
#
# THE RULE. Every construction must be either
#   (a) `Solana::Config.client`, or
#   (b) `Solana::Client.new(rpc_url: <expression naming Config>)` — the escape
#       hatch for a caller that genuinely needs to name its own endpoint. The
#       value still has to come from Config, so a raw ENV read or a pasted
#       literal is an offender too.
class ClientRoutedThroughConfigTest < ActiveSupport::TestCase
  # Ruby the app actually loads. `test/` is excluded on purpose: fakes and
  # fixtures build clients against local stub endpoints by design.
  SCANNED_GLOBS = %w[app/**/*.rb lib/**/*.rb lib/**/*.rake config/**/*.rb].freeze

  # `Solana::Client.new` is the fully-qualified form used everywhere. A bare
  # `Client.new` also resolves to it inside the Solana namespace, so those
  # directories are matched loosely too — without dragging in `Cdp::Client.new`
  # / `Paypal::Client.new`, which are unrelated HTTP clients.
  QUALIFIED  = /Solana::Client\.new/
  BARE_NS    = /(?<![\w:])Client\.new/
  BARE_NS_DIRS = %w[app/services/solana/ app/jobs/solana/ app/models/solana/].freeze

  # The single sanctioned construction: the factory's own body.
  FACTORY_LINE = "app/services/solana/config.rb"

  # HELD, not forgiven. `Solana::Vault.ensure_program_id_live!` is being
  # rewritten right now by the parallel `harden-solana-health-reporting` lane
  # (it changes that method's signature, return contract and rescue arm), so
  # routing its one bare construction here would collide for no safety gain
  # this branch can bank. The count is PINNED at 1: if that lane lands and
  # leaves the line bare, this still passes; if anyone adds a SECOND bare
  # construction to vault.rb, this fails. Drop the entry once the sibling lane
  # merges — the swap is `client ||= Config.client`.
  HELD_BARE_COUNTS = { "app/services/solana/vault.rb" => 1 }.freeze

  def root
    @root ||= Rails.root
  end

  def offending_lines
    SCANNED_GLOBS.flat_map { |glob| Dir[root.join(glob)] }.sort.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(root).to_s
      loose = BARE_NS_DIRS.any? { |dir| rel.start_with?(dir) }

      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(QUALIFIED) || (loose && line.match?(BARE_NS))
        # (b) the explicit-endpoint escape hatch, sourced from Config.
        next if line.include?("rpc_url:") && line.include?("Config")
        # The factory itself.
        next if rel == FACTORY_LINE
        ["#{rel}:#{index + 1}", line.strip]
      end
    end
  end

  test "no Solana client is constructed outside Solana::Config" do
    held, offenders = offending_lines.partition do |location, _|
      HELD_BARE_COUNTS.key?(location.split(":").first)
    end

    assert_empty offenders.map { |location, source| "#{location}  #{source}" },
      "these build a Solana RPC client without going through Solana::Config, so they fall " \
      "through to the gem's ENV.fetch(\"SOLANA_RPC_URL\", <public devnet>) — which FAILS OPEN " \
      "where Solana::Config::RPC_URL fails closed (OPSEC-012), and sits outside the " \
      "public/credentialed split. Use `Solana::Config.client`, or pass an explicit " \
      "`rpc_url:` sourced from Solana::Config."

    held_counts = held.group_by { |location, _| location.split(":").first }
                      .transform_values(&:size)
    assert_equal HELD_BARE_COUNTS, held_counts,
      "the held bare-construction budget moved. Held entries are pinned to an exact count so a " \
      "NEW bare client cannot hide behind an existing exemption — see HELD_BARE_COUNTS."
  end

  test "the factory is the only sanctioned construction in config.rb" do
    source = File.read(root.join(FACTORY_LINE))
    constructions = source.scan(/Solana::Client\.new\([^)]*\)/)

    assert_equal ["Solana::Client.new(rpc_url: rpc_url)"], constructions,
      "Solana::Config must construct the client exactly once, forwarding its own endpoint."
  end

  test "Config.client defaults to the configured server endpoint" do
    # The gem exposes no reader for the endpoint, so read the ivar it parsed.
    endpoint = Solana::Config.client.instance_variable_get(:@rpc_url)
    assert_equal Solana::Config::RPC_URL, endpoint
  end

  test "Config.client forwards an explicit endpoint" do
    # A deliberately fake local endpoint — never a real one, never credentialed.
    override = "http://127.0.0.1:8899"
    endpoint = Solana::Config.client(rpc_url: override).instance_variable_get(:@rpc_url)
    assert_equal override, endpoint
  end
end
