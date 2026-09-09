require "test_helper"

# The seams between the three artifacts that make client-failure reporting work:
# the JS reporter (app/javascript/solana_errors.js), the call site that invokes
# it (a modal's x-data), and the server that receives it.
#
# WHY THESE ASSERTIONS AND NOT "THE STRING IS PRESENT". Grepping rendered markup
# for `reportWalletFailure` proves the characters shipped and nothing else — the
# path could 404, the stage could be one the server has never heard of, and every
# such assertion would still pass. Each test below instead couples TWO artifacts
# and fails when either moves alone. Whether the behaviour actually works is the
# e2e tier's job (e2e/wallet_failure_report.spec.js), not this one's.
class WalletFailureReporterWiringTest < ActionDispatch::IntegrationTest
  REPORTER_JS = "app/javascript/solana_errors.js".freeze

  # THE BOUNDARY, MADE EXECUTABLE. Three render surfaces catch these rejections.
  # ONE is in this repo. The other two are in the solana-studio GEM, WIRED THERE
  # SINCE 0.7.0 — so all five stages report today, and the two Hashes below split
  # on WHERE THE CALL SITE LIVES, not on whether it fires.
  #
  # THIS COMMENT IS THE DEFECT THE FLOOR TEST NOW GUARDS. It read "unwired today,
  # on purpose" from the day 0.7.0 landed until 2026-09-09 — three gem releases —
  # while docs/AUTH.md cited THIS FILE as its executable accounting, so a reader
  # following the doc's own cross-reference landed on the opposite claim. Nothing
  # reddened, and the reason is worth stating: "every stage the server knows is
  # wired in this repo or named in the gem" asserts that the two Hashes COVER
  # STAGES — the union, never which side a stage is on. A prose classification
  # cannot check itself. The floor test at the bottom is the half that can.
  #
  # The LAYOUT is wired too, and it is not a surface — it is TWO call sites in
  # one file. solanaConnectAndVerify substitutes a sentence of its own in two
  # places (a connect() that never answered, and a connect() that answered
  # before signMessage refused), and each substitution is the last place the
  # wallet's words exist on its path — see the STAGES comment in
  # Solana::ClientFailureReport. The gem's two surfaces do not replace either,
  # because by the time they catch, the substitution has already happened.
  # Note this Hash is stage => file and two stages share one file;
  # the per-site test below scans that file for EVERY stage it sends, so a
  # second call site cannot hide behind the first.
  WIRED_STAGES = {
    "wallet_setup_connect"     => "app/views/modals/_wallet_setup.html.erb",
    "connect_verify_fallback"  => "app/views/layouts/application.html.erb",
    "connect_verify_signature" => "app/views/layouts/application.html.erb"
  }.freeze

  # The two call sites that live in the solana-studio GEM, wired there since
  # 0.7.0. Named for WHERE THEY ARE, because the old name encoded a STATUS
  # (PENDING_GEM_STAGES) and a status in a constant name rots exactly the way
  # that one did — it read "pending" for three releases after the gem shipped.
  #
  # THEY CANNOT SIMPLY MOVE INTO WIRED_STAGES. That Hash is stage => a file in
  # THIS repo, and "each wired call site sends a stage the server actually
  # recognises" reads those files off disk. The gem's two have no such file
  # here, so the per-site scan has nothing to run and the split survives the
  # wiring.
  #
  # Deliberately NOT asserted against the gem's own SOURCE. A turf-monster test
  # that reddens when solana-studio moves these call sites would red-seal the
  # producer's release against a consumer's bookkeeping. The accounting lives
  # here; the wiring lives there. What IS assertable is a fact about THIS repo —
  # the version its own lockfile resolves. See the floor test below.
  GEM_STAGES = {
    "wallet_connect" => "solana-studio: solana_studio/modals/_wallet_connect.html.erb",
    "web3_step_up"   => "solana-studio: solana_studio/modals/_web3_step_up.html.erb"
  }.freeze

  # The solana-studio release that WIRED the two stages above: commit 06bda3b,
  # "Report wallet failures from both web3 modals", whose EARLIEST containing tag
  # is v0.7.0. Stated as the earliest containing tag rather than as a list of
  # tags that carry it, because a list is falsified by the very next release —
  # this repo has already paid for that mistake at length (see Gemfile:108).
  #
  # DERIVED, not read off a changelog. Across the installed gem corpus,
  # solana_studio/modals/_wallet_connect.html.erb EXISTS from 0.5.3 carrying
  # ZERO `reportWalletFailure` call sites through 0.6.1, and carries three from
  # 0.7.0 onward; _web3_step_up.html.erb moves with it. So 0.6.1 is the last
  # release where this file's old "unwired" reading was true, and the corpus
  # says the transition is a step rather than a drift.
  GEM_STAGES_WIRED_SINCE = Gem::Version.new("0.7.0")

  test "the URL the browser posts to resolves to the endpoint that records" do
    # THE FAILURE THIS CATCHES: a reporter aimed at a path that 404s. It is
    # invisible to every other tier — the endpoint's tests pass (they call the
    # route directly), the modal renders, and the reports simply never arrive.
    # Reading the literal out of the shipped JS and pushing it through the real
    # router is what couples the two halves.
    source = Rails.root.join(REPORTER_JS).read
    path = source[/fetch\('([^']+)'/, 1]
    assert path.present?, "could not find the reporter's fetch URL in #{REPORTER_JS}"

    route = Rails.application.routes.recognize_path(path, method: :post)

    assert_equal "solana_sessions", route[:controller]
    assert_equal "report_failure", route[:action]
  end

  test "every stage the server knows is wired in this repo or named in the gem" do
    # Nothing may fall off the list silently in either direction: a stage the
    # server declares but nobody sends is dead weight, and a stage sent by a call
    # site the server has never heard of is recorded as `unknown` with no error.
    assert_equal Solana::ClientFailureReport::STAGES.sort,
                 (WIRED_STAGES.keys + GEM_STAGES.keys).sort,
                 "a stage was added or removed without updating the wiring ledger above"
  end

  test "each wired call site sends a stage the server actually recognises" do
    # The cross-artifact check. A typo'd stage does not fail anywhere — it is
    # normalised to `unknown` and the row loses the one field an operator filters
    # on. This is the only place the two spellings meet.
    WIRED_STAGES.each do |stage, file|
      source = Rails.root.join(file).read
      sent = source.scan(/window\.reportWalletFailure\('([^']+)'/).flatten

      assert_includes sent, stage,
                      "#{file} no longer reports stage #{stage.inspect}"
      sent.each do |value|
        assert_includes Solana::ClientFailureReport::STAGES, value,
                        "#{file} sends stage #{value.inspect}, which the server maps to `unknown`"
      end
    end
  end

  test "the reporter is on a module the application bundle actually loads" do
    # A reporter in an unpinned or unimported file is a `typeof` guard that is
    # false forever — every call site degrades to silence and nothing anywhere
    # goes red. Both halves of importmap delivery are asserted because either one
    # alone is insufficient.
    module_name = File.basename(REPORTER_JS, ".js")

    assert_includes Rails.root.join("config/importmap.rb").read, %(pin "#{module_name}"),
                    "#{REPORTER_JS} is not pinned — the browser can never load it"
    assert_includes Rails.root.join("app/javascript/application.js").read, %(import "#{module_name}"),
                    "#{REPORTER_JS} is pinned but never imported"
  end

  test "the permitted keys and the keys the report actually reads are one set" do
    # WHERE THE PII ALLOWLIST IS REALLY ENFORCED, pinned because a mutant showed
    # the obvious answer is wrong. Widening #client_failure_params to permit
    # :signature, :nonce and :message left every test green — permitting a key
    # stores nothing on its own, because ClientFailureReport.from_params reads
    # four keys by name and never looks at the rest of the hash. The permit list
    # is the OUTER layer; `from_params` is the load-bearing one.
    #
    # So assert them as ONE set, which makes both halves killable: widening the
    # permit list without widening the reader fails here, and widening the reader
    # without widening the permit list fails here too. Either alone is a silent
    # change to what can reach an error_logs row.
    read = []
    probe = Object.new
    probe.define_singleton_method(:[]) { |key| read << key.to_sym; nil }
    Solana::ClientFailureReport.from_params(probe)

    controller = Rails.root.join("app/controllers/solana_sessions_controller.rb").read
    permitted = controller[/def client_failure_params\s*\n\s*params\.permit\(([^)]*)\)/m, 1]
    assert permitted.present?, "could not find client_failure_params' permit list"
    permitted = permitted.scan(/:(\w+)/).flatten.map(&:to_sym).sort

    assert_equal %i[mapped_message provider raw_message stage], read.uniq.sort,
                 "ClientFailureReport.from_params changed which keys it reads"
    assert_equal permitted, read.uniq.sort,
                 "the controller permits a key the report never reads, or vice versa"
  end

  test "the reporter uses the SAME csrf plumbing as the wallet-auth POST beside it" do
    # THE PRODUCTION PATH NOTHING ELSE HERE TOUCHES, and the reason is worth
    # stating plainly: `allow_forgery_protection` is FALSE in the test env, AND
    # Playwright drives a test-env server, so every other assertion about this
    # endpoint in this repo is made with CSRF switched OFF. Two attempts to arm
    # it inside an integration test (2026-09-07, on ActionController::Base and on
    # ApplicationController) did not engage, and with it off Rails renders no
    # csrf_meta_tags at all — which is why e2e/phantom-mock.js has to inject a
    # fake one. A green test that never armed the thing it names is worse than
    # no test, so this asserts something else, and something checkable.
    #
    # MEASURED against a live development stack on :3121, 2026-09-07:
    #   no token             -> 422, NO report row
    #   X-CSRF-Token: <token> -> 204, row written
    #
    # So the token is genuinely required, and a mismatch on either name refuses
    # every report silently — no raise, no broken sign-in, this surface dark
    # again in exactly the way it already was. What IS assertable is that the
    # reporter uses the identical plumbing to `solanaConnectAndVerify`'s POST to
    # /auth/solana/verify, three hundred lines up the same page — an endpoint
    # already proven in production every time somebody signs in with a wallet.
    # If that pair is ever renamed, both move together or this goes red.
    reporter = Rails.root.join(REPORTER_JS).read
    layout = Rails.root.join("app/views/layouts/application.html.erb").read

    assert_includes layout, "'X-CSRF-Token': document.querySelector('meta[name=\"csrf-token\"]')",
                    "the wallet-auth POST's csrf plumbing moved — re-derive what the reporter should copy"

    assert_includes reporter, %(querySelector('meta[name="csrf-token"]')),
                    "the reporter reads a meta name the app does not render"
    assert_includes reporter, "'X-CSRF-Token'",
                    "the reporter sends a header name Rails does not read"
  end

  test "the reporter never sends a credential-bearing key" do
    # Layer 1 of the PII rule, asserted at the SENDER as well as the receiver.
    # The receiving half is the permit-list/reader PAIR asserted directly above —
    # NOT the permit list alone, which a mutant proved stores nothing by itself.
    # This test is the third point on the same rule: a credential is never SENT,
    # so it never crosses the wire and never lands in an access log or a proxy
    # buffer on the way to a receiver that would have refused it anyway.
    body = Rails.root.join(REPORTER_JS).read[/JSON\.stringify\(\{(.*?)\}\)/m, 1]
    assert body.present?, "could not find the reporter's request body"

    keys = body.scan(/^\s*(\w+):/).flatten.sort
    assert_equal %w[mapped_message provider raw_message stage], keys,
                 "the reporter's body changed shape — every key here is stored verbatim"
  end

  test "the resolved solana-studio carries the wiring GEM_STAGES claims" do
    # THE HALF NO COMMENT CAN CHECK, and the reason this test exists. GEM_STAGES
    # asserts two stages report from inside the gem. That is true only while the
    # solana-studio this app actually installs carries the call sites — and the
    # ledger read the OPPOSITE for three releases with nothing anywhere going
    # red, because the union test above never asks which side a stage is on.
    #
    # A FLOOR, NEVER AN EQUALITY. `assert_equal "0.9.1", version` looks tighter
    # and is strictly worse: it goes red the moment solana-studio ships 0.9.2,
    # which is precisely the red-seal this file's whole design refuses — a
    # consumer's bookkeeping failing the producer's release. The question the
    # ledger actually asks is "is the wiring in there", and that answer is
    # MONOTONIC: every version at or above the floor carries it, so a floor is
    # the assertion that matches the claim's shape. An equality would also be
    # false on arrival for anyone who bumps the gem, making the guard a chore
    # rather than a check.
    #
    # THE LOCKFILE, not the loaded constant, because the lockfile is the fact
    # about THIS repo: it is committed, it is what CI (`bundler-cache: true`)
    # and the deploy install from, and it is readable in a diff. Reading the
    # gem's own source instead would close the gap the wrong way — see the
    # GEM_STAGES comment.
    locked = Bundler.locked_gems.specs.find { |spec| spec.name == "solana-studio" }
    refute_nil locked,
               "solana-studio is not in Gemfile.lock at all — the two GEM_STAGES have no source"

    assert_operator locked.version, :>=, GEM_STAGES_WIRED_SINCE,
                    "Gemfile.lock resolves solana-studio #{locked.version}, BELOW the " \
                    "#{GEM_STAGES_WIRED_SINCE} that wired #{GEM_STAGES.keys.sort.join(' and ')}. " \
                    "Below that floor those two stages report nothing, while this file and " \
                    "docs/AUTH.md's call-site table both say they are wired — the contradiction " \
                    "this guard exists to make loud. Either raise the resolve, or mark both rows " \
                    "unwired in BOTH places. Note the Gemfile pin `~> 0.6` still ADMITS 0.6.x, " \
                    "so this test is the only thing refusing that resolve."
  end
end
