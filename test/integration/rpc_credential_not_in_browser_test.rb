require "test_helper"

# OPSEC — the browser must never receive a CREDENTIAL-BEARING RPC URL.
#
# THE BUG (pre-existing; surfaced in the Carl+Jasper review of
# require-solana-rpc-in-production). Six browser-facing surfaces emitted
# `Solana::Config::RPC_URL` — the SERVER's RPC endpoint — verbatim into the
# response body:
#
#   app/views/layouts/application.html.erb      body[data-solana-rpc-url]
#   app/views/layouts/modal_preview.html.erb    body[data-solana-rpc-url]
#   app/views/admin/pending_transactions/…      #cosign-config[data-rpc-url]
#   app/controllers/admin/vault_state_controller.rb   -> @rpc_url -> same div
#   app/controllers/admin/vault_init_controller.rb    -> @rpc_url -> same div
#   app/controllers/proof_of_reserves_controller.rb   -> @page_config[:rpc_url]
#
# FIVE OF THEM ARE GUARDED BELOW; the sixth stopped existing. layouts/modal_preview
# was deleted on 2026-09-09 with the /admin/modals/preview seam it served, so its
# guard went with it rather than being rehomed — a surface that cannot render
# cannot leak, and a test kept pointing at a deleted layout would only assert
# that the deletion happened. The list above is left INTACT because it is the
# incident's record: it says what the audit found, and shrinking it would make
# the count in the sentence above it wrong.
#
# On the mainnet app that constant is a paid provider endpoint carrying an
# `api-key` query param, so every page load shipped a provider credential to
# every browser — and proof-of-reserves is UNAUTHENTICATED and additionally
# renders the value as visible page text. The tell that the codebase already
# knew: lib/tasks/solana.rake and lib/tasks/solana_preflight.rake both redact
# `api-key=…` before printing the same constant to a TERMINAL.
#
# HOW THIS TEST WORKS. The real secret is never written down anywhere. The
# suite substitutes a provider-SHAPED but entirely fake endpoint for
# Solana::Config::RPC_URL, then asserts on a REDACTION PREDICATE
# (`Solana::Config.credentialed_rpc_url?`) rather than on the literal — the
# invariant is "nothing credentialed reaches the DOM", which has to hold for a
# key nobody typed into this file. SENTINEL_ABSENT is the belt to that braces.
class RpcCredentialNotInBrowserTest < ActionDispatch::IntegrationTest
  # Deliberately fake. Its only job is to be conspicuous if it escapes.
  SENTINEL  = "TEST-SENTINEL-NOT-A-REAL-KEY-0000".freeze
  KEYED_RPC = "https://mainnet.helius-rpc.com/?api-key=#{SENTINEL}".freeze

  # RPC_URL is a LOAD-TIME constant (deliberately — see the OPSEC-012 comment
  # in config.rb, and the constant-form pin in config_rpc_required_test.rb), so
  # swapping the constant is the only way to put a credentialed value on the
  # server side. Rails parallelizes by FORK, so this never crosses workers.
  def with_keyed_rpc_url
    previous = Solana::Config::RPC_URL
    Solana::Config.send(:remove_const, :RPC_URL)
    Solana::Config.const_set(:RPC_URL, KEYED_RPC)
    yield
  ensure
    Solana::Config.send(:remove_const, :RPC_URL)
    Solana::Config.const_set(:RPC_URL, previous)
  end

  # One assertion shared by every surface.
  #   1. the fake credential is nowhere in the response, and
  #   2. the value the page DID hand the browser is non-blank (the client RPC
  #      path still works) and passes the redaction predicate.
  # (2) is what keeps this honest: deleting the attribute entirely would
  # satisfy (1) while breaking every client-side transaction.
  def assert_browser_rpc_clean(emitted, body, surface)
    assert_no_match(/#{Regexp.escape(SENTINEL)}/, body,
      "#{surface}: the server's api-keyed RPC URL reached the browser response body")
    assert emitted.present?,
      "#{surface}: emitted NO RPC URL — the client RPC path needs one (see acceptance criterion 2)"
    refute Solana::Config.credentialed_rpc_url?(emitted),
      "#{surface}: emitted a credential-bearing RPC URL (#{Solana::Config.redact_rpc_url(emitted)})"
  end

  def body_data_solana_rpc_url(body)
    body[/<body[^>]*\sdata-solana-rpc-url="([^"]*)"/, 1]
  end

  def cosign_config_rpc_url(body)
    body[/id="cosign-config"[^>]*\sdata-rpc-url="([^"]*)"/, 1]
  end

  def proof_of_reserves_rpc_url(body)
    json = body[%r{<script type="application/json" id="proof-of-reserves-config">\s*(.*?)\s*</script>}m, 1]
    assert json, "proof-of-reserves: the #proof-of-reserves-config JSON block is gone"
    JSON.parse(json)["rpc_url"]
  end

  # The two admin vault pages render the live VaultState. FakeVault's default
  # state omits :signers / :threshold (the views call .length on them), so seed
  # a complete one here rather than widen the shared double for every suite.
  def fake_vault_with_state
    vault = FakeVault.new
    vault.vault_state = {
      pda:                "vault-pda",
      threshold:          2,
      signers:            Solana::Config::MULTISIG_SIGNERS,
      paused:             false,
      usdc_mint:          Solana::Config::USDC_MINT,
      usdt_mint:          Solana::Config::USDT_MINT,
      vault_usdc:         "11111111111111111111111111111111",
      vault_usdt:         "11111111111111111111111111111111",
      treasury_authority: "11111111111111111111111111111111",
      accepted_currencies: []
    }
    vault
  end

  # --- the standing guard, for surfaces this sweep does not visit ---

  # The request tests above can only assert about pages they GET. This one
  # holds for a view that does not exist yet: no ERB template, and no shipped
  # JavaScript, may name the SERVER's RPC constant at all. Views and
  # app/javascript are unambiguously browser-facing, so the ban is total there
  # — unlike controllers and services, which use `Solana::Config::RPC_URL`
  # legitimately and constantly (that is the whole point of having two).
  test "no view or client script names the server RPC constant" do
    root = Rails.root
    offenders = Dir[root.join("app/views/**/*.erb"), root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).include?("Config::RPC_URL")
    end

    assert_empty offenders.map { |path| Pathname.new(path).relative_path_from(root).to_s },
      "these browser-facing files name Solana::Config::RPC_URL — the SERVER endpoint, " \
      "which carries the provider api-key on mainnet. Use Solana::Config.public_rpc_url."
  end

  # --- the application layout: EVERY page, logged in or out ---

  test "the application layout hands the browser a non-credentialed RPC URL" do
    with_keyed_rpc_url do
      get contests_path
      assert_response :success
      assert_browser_rpc_clean(body_data_solana_rpc_url(response.body), response.body,
                               "layouts/application body[data-solana-rpc-url]")
    end
  end

  test "a LOGGED-OUT visitor never receives the credentialed RPC URL" do
    with_keyed_rpc_url do
      get contests_path
      assert_response :success
      assert_no_match(/#{Regexp.escape(SENTINEL)}/, response.body,
        "an unauthenticated page load shipped the provider credential")
    end
  end

  # --- proof-of-reserves: PUBLIC, and renders the URL as visible page text ---

  test "the PUBLIC proof-of-reserves page never receives the credentialed RPC URL" do
    with_keyed_rpc_url do
      get proof_of_reserves_path
      assert_response :success
      assert_browser_rpc_clean(proof_of_reserves_rpc_url(response.body), response.body,
                               "proof_of_reserves #page_config[:rpc_url]")
    end
  end

  # --- the three admin cosign surfaces ---

  # This surface no longer hands the browser an RPC URL AT ALL, and that is a
  # deliberate strengthening rather than a way around assert_browser_rpc_clean.
  #
  # Read clause (2) of that helper first: it refuses a surface that emits
  # nothing, because "deleting the attribute entirely would satisfy (1) while
  # breaking every client-side transaction." That reasoning is exactly right for
  # the other five surfaces, which still build and send transactions in the
  # browser. It stopped applying HERE on 2026-09-05, when the cosign page handed
  # its broadcast to the server (Admin::PendingTransactionsController#broadcast
  # → Solana::Vault#simulate_and_broadcast). This page's browser now signs with
  # Phantom and POSTs the wire back; it never opens a Connection, so there is no
  # client RPC path left to break.
  #
  # So the invariant tightens instead of loosening: a URL that is never emitted
  # cannot carry a credential. Asserting the ABSENCE is what pins the new
  # architecture — if someone reintroduces a browser-side broadcast here, they
  # have to reintroduce the RPC handle, and this test fails and sends them back
  # to read why it went away.
  #
  # The sentinel check is kept verbatim: it is the original security property
  # and it must hold no matter how the page is built.
  test "the admin pending-transactions page hands the browser no RPC URL at all" do
    log_in_as(users(:alex))
    with_keyed_rpc_url do
      get admin_pending_transactions_path
      assert_response :success

      assert_no_match(/#{Regexp.escape(SENTINEL)}/, response.body,
        "admin/pending_transactions: the server's api-keyed RPC URL reached the browser response body")

      assert_nil cosign_config_rpc_url(response.body),
        "admin/pending_transactions: an RPC URL is back in the page — this surface broadcasts " \
        "server-side and must not hand the browser an endpoint (see #broadcast)"
      assert_no_match(/id="cosign-config"/, response.body,
        "admin/pending_transactions: #cosign-config is back; the server owns this broadcast now")
    end
  end

  test "the admin vault-state cosign config carries no credential" do
    log_in_as(users(:alex))
    with_keyed_rpc_url do
      Solana::Vault.stub :new, fake_vault_with_state do
        get admin_vault_state_path
      end
      assert_response :success
      assert_browser_rpc_clean(cosign_config_rpc_url(response.body), response.body,
                               "admin/vault_state #cosign-config")
    end
  end

  test "the admin vault-init cosign config carries no credential" do
    log_in_as(users(:alex))
    with_keyed_rpc_url do
      Solana::Vault.stub :new, fake_vault_with_state do
        get admin_vault_init_path
      end
      assert_response :success
      assert_browser_rpc_clean(cosign_config_rpc_url(response.body), response.body,
                               "admin/vault_init #cosign-config")
    end
  end
end
