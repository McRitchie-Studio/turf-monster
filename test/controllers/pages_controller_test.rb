require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "terms page renders without auth" do
    get terms_path
    assert_response :success
    assert_select "h1", /Terms of Service/
    assert_select "a[href=?]", privacy_path
  end

  test "privacy page renders without auth" do
    get privacy_path
    assert_response :success
    assert_select "h1", "Privacy Policy"
    assert_select "a[href=?]", terms_path
  end

  test "about page renders without auth" do
    get about_path
    assert_response :success
    assert_select "h1", "About Turf Monster"
    assert_select "a[href=?]", contact_path
  end

  # /about carried the same per-contest misdescription of the operator-revenue
  # account that /contract did. The ATA is derived from [b"op_rev", mint] alone
  # (enter_contest.rs:95), so it is one account per currency for the whole
  # vault, shared by every contest. Assert the topology, not the sentence.
  test "about page does not call operator revenue a per-contest account" do
    get about_path

    assert_response :success
    # The separator is written loose on purpose: the apostrophe reaches the body
    # as &rsquo; (7 chars) here, and would arrive as &#39; if the copy switched to
    # a plain one. A guard pinned to one spelling is a guard that never bites.
    assert_no_match(/contest.{0,8}s operator[- ]revenue/i, response.body)
    assert_match(/operator revenue account/i, response.body)
  end

  test "contact page renders without auth" do
    get contact_path
    assert_response :success
    assert_select "h1", "Contact"
    assert_select "a[href=?]", about_path
  end

  test "global footer exposes the legitimacy + transparency links" do
    get terms_path
    assert_response :success
    # Footer is rendered in the application layout, so it appears on every
    # app page. These links are the site-legitimacy signals wallet scanners
    # look for; assert they are discoverable.
    %i[about_path contact_path privacy_path terms_path proof_of_reserves_path
       responsible_gaming_path state_eligibility_path].each do |helper|
      assert_select "footer a[href=?]", send(helper), { minimum: 1 },
        "footer should link to #{helper}"
    end
  end

  # ── underwriting compliance pages ─────────────────────────────────────────

  test "responsible gaming page renders without auth with the required resources" do
    get responsible_gaming_path
    assert_response :success
    assert_select "h1", /Responsible Gaming/
    # Problem-gambling resources underwriters check for.
    assert_match "1-800-GAMBLER", response.body
    assert_select "a[href*=?]", "ncpgambling.org"
    # Self-exclusion contact + commitment language.
    assert_select "a[href=?]", "mailto:alex@turfmonster.media"
    assert_match(/close your account/i, response.body)
  end

  # ── versioned rules pages ─────────────────────────────────────────────────
  #
  # TWO rules pages, one per SEASON. /turf-totals-v1 documents the World Cup
  # format; /turf-monster-v1 documents the NFL one. They are not variants of the
  # same copy — the sports price and score differently — so the tests below pin
  # the NFL page to the NFL rules and assert the older page still answers.

  test "NFL rules page renders without auth" do
    get turf_monster_v1_path

    assert_response :success
    assert_select "h1", /Turf\s*Monster/
    assert_match "NFL 2026", response.body
  end

  # Scoped to the page's own subtree, not response.body: the layout ships
  # site-wide meta that still describes the World Cup season, and a whole-body
  # scan reads that chrome rather than this page.
  def rules_page_text
    node = css_select('[data-test="turf-monster-rules"]').first
    assert node, "the rules page must render its own subtree"
    node.text
  end

  test "NFL rules page leads with the four play steps in order" do
    get turf_monster_v1_path

    assert_response :success
    steps = ["Pick a contest", "Choose your teams", "Watch the leaderboard", "Win prizes"]
    text = rules_page_text
    positions = steps.map { |step| text.index(step) }

    assert_equal [], steps.zip(positions).select { |_, at| at.nil? }.map(&:first),
                 "every play step must appear on the page"
    assert_equal positions, positions.sort,
                 "the steps must read in order: #{steps.join(' -> ')}"
  end

  # THE OPERATOR RULE THIS PAGE IS BUILT ON: it teaches game play, and hands
  # every question about what an entry COSTS to the Web3 onboarding guide. A
  # dollar figure sitting here with no way through to /getting-started is the
  # regression — so assert the link is present more than once (hero, prizes,
  # quick reference, footer) rather than merely somewhere.
  test "NFL rules page routes entry cost to the Web3 onboarding guide" do
    get turf_monster_v1_path

    assert_response :success
    # FOUR, not "at least a few": the page names cost in four places — the play
    # steps, the Prizes section, the Quick Reference row, and the closing CTA —
    # and each one carries its own way through. A floor of 3 let a link be
    # deleted with the guard still green (measured by mutation, 2026-09-06).
    # SCOPED to the page's own subtree. The layout ships two more
    # /getting-started links of its own, so an unscoped assert_select counts SIX
    # and a floor of four stays green after a page link is deleted — measured by
    # mutation, 2026-09-06, and the same trap the World Cup assertion below hit.
    assert_select '[data-test="turf-monster-rules"] a[href=?]', getting_started_path, { minimum: 4 },
                  "each entry-cost mention must send the reader to the onboarding guide"
    assert_match(/USDC/, rules_page_text)
  end

  # The page is NFL, and the multiplier curve is the tell: the NFL curve is
  # linear and tops out at x2.0 (SlateMatchup.turf_score_for, sport: "nfl"),
  # while the World Cup curve is logarithmic to x3.0. Copy that drifted back to
  # the soccer numbers would still render, still read fine, and be wrong.
  test "NFL rules page states the NFL multiplier curve, not the soccer one" do
    get turf_monster_v1_path

    assert_response :success
    text = rules_page_text
    assert_match(/1\.0/, text)
    assert_match(/2\.0/, text)
    assert_no_match(/3\.0\s*[x\u00d7]/i, text, "3.0x is the World Cup ceiling, not the NFL one")
    assert_no_match(/World Cup/i, text, "this page documents the NFL season")
    # NOT a blunt /goals?/ refutation — "field goal" is the NFL's own word and
    # appears twice on this page legitimately. What must never come back is the
    # soccer SCORING UNIT, so pin the unit sentence positively and refute the
    # phrasings that would replace it.
    assert_match(/points scored/i, text, "the scoring unit is points scored")
    assert_no_match(/goals scored|goals\s*[x\u00d7]\s*Turf/i, text,
                    "the NFL page scores points, not goals")
  end

  # Every number in the worked example is re-derived here, so the table cannot
  # quietly go wrong: each row is (its three weekly point totals, summed) times
  # its Turf Score, and the footer total is the sum of the rows.
  test "NFL rules page scoring example adds up" do
    get turf_monster_v1_path

    assert_response :success
    rows = css_select('table[data-test="scoring-example"] tbody tr')
    assert_equal 6, rows.size, "the example entry is six teams"

    derived = rows.map do |row|
      cells = row.css("td").map { |cell| cell.text.strip }
      weekly = cells[1..3].map(&:to_i)
      multiplier = cells[4].delete_suffix("x").to_f
      scored = cells[5].to_f

      assert_equal (weekly.sum * multiplier).round(1), scored,
                   "#{cells[0]}: #{weekly.inspect} x #{multiplier} should be #{(weekly.sum * multiplier).round(1)}"
      scored
    end

    total = css_select('table[data-test="scoring-example"] tfoot td').last.text.strip.to_f
    assert_equal derived.sum.round(1), total, "the total must be the sum of the rows"
  end

  # THE BLOCKER THIS ENCODES (review, 2026-09-07). The page shipped to review
  # promising "no withdrawal request, no waiting on a payout queue". All three
  # timing claims were false:
  #
  #   * nothing grades at the final whistle — Contest#grade! is reached only from
  #     ContestsController#grade (admin) and the QA rehearsal driver, and none of
  #     the five cron jobs in config/schedule.yml grades or settles a contest;
  #   * settlement IS a queue — Contest#settle_onchain! builds a PARTIALLY-SIGNED
  #     transaction into PendingTransaction(tx_type: "settle_contest") for 2-of-3
  #     multisig cosigning, which an admin confirms. Production was holding
  #     settle pt#298 for two days when this was caught;
  #   * only WHERE the money goes was true (entry.user.solana_address).
  #
  # Green CI, correct numbers, and a false money claim on a public real-money
  # page. Nobody here knows the payout SLA, so the page must promise none — and
  # the fix for that is not vigilance, it is this test. Scoped to the page's own
  # subtree so the layout's marketing copy cannot satisfy or trip it.
  PAYOUT_PROMISES = [
    /no waiting/i, /no withdrawal/i, /instantly/i, /immediately/i,
    /right away/i, /straight away/i, /within \s*\d+\s*(second|minute|hour|day)/i,
    /as soon as the (?:last )?game/i, /no queue/i, /automatic(?:ally)? paid/i
  ].freeze

  test "the NFL rules page promises no payout SLA" do
    get turf_monster_v1_path

    assert_response :success
    text = rules_page_text

    offenders = PAYOUT_PROMISES.select { |pattern| text.match?(pattern) }
    assert_empty offenders,
                 "settlement is a 2-of-3 multisig queue with no published SLA — this page " \
                 "may say WHERE winnings go, never WHEN: #{offenders.join(', ')}"
  end

  # THE SAME DEFECT, ONE SECTION UP — found by applying review's rule to the rest
  # of the page rather than only to the line it named. The leaderboard copy said
  # scores land "in real time" and update "while the games are being played".
  # Goal creation really does broadcast live (goal.rb), but a Goal only exists
  # once Nfl::LiveScores::PollCycle has run, and its own header says it is
  # "called on a fixed cadence by an agent" — no cron in config/schedule.yml
  # drives it. So the latency is an operational process with no SLA, exactly like
  # settlement. The page may describe the MECHANISM; it may not promise a clock.
  SCORING_LATENCY_PROMISES = [
    /in real ?time/i, /live updates/i, /the moment (?:a|the|they)/i,
    /within seconds/i, /instant(?:ly)? updat/i, /as (?:the games|it) happens?/i
  ].freeze

  test "the NFL rules page promises no scoring latency either" do
    get turf_monster_v1_path

    assert_response :success
    text = rules_page_text

    offenders = SCORING_LATENCY_PROMISES.select { |pattern| text.match?(pattern) }
    assert_empty offenders,
                 "live scores depend on an agent-driven poll cycle with no SLA — describe the " \
                 "mechanism, never the clock: #{offenders.join(', ')}"
  end

  # The true half of the claim has to survive the guard above, or a later edit
  # satisfies it by deleting the payout sentence altogether.
  test "the NFL rules page still says where winnings go" do
    get turf_monster_v1_path

    assert_response :success
    assert_match(/payouts go to the wallet you entered from/i, rules_page_text,
                 "dropping the SLA must not drop the destination")
  end

  # THE MONEY IS DERIVED, like the multipliers. Review found the payouts and
  # contest size hard-typed in two sections while every multiplier was derived —
  # and Contest::FORMATS carries five other live formats.
  test "the NFL rules page prints the money Contest::FORMATS carries" do
    get turf_monster_v1_path

    assert_response :success
    text = rules_page_text
    format = Contest::FORMATS.fetch("medium")

    format[:payouts].each_value do |cents|
      assert_match(/\$#{format('%.2f', cents / 100.0)}/, text,
                   "the payout table must print FORMATS' own amounts")
    end
    assert_match(/#{format[:max_entries]} entries/, text)
    assert_match(/\$#{format('%.2f', format[:payouts].values.sum / 100.0)}/, text,
                 "the prize pool is the sum FORMATS defines")
  end

  # The published formula has to reproduce the multiplier a player is PAID.
  # SlateMatchup.turf_score_for rounds to one decimal, and that rounded value is
  # what freezes onto the pick — so ranks 1 and 2 both pay 1.0x. A reader
  # computing rank 5 from an unrounded formula gets 1.129 and is paid 1.1.
  test "the NFL rules page states that the curve is rounded" do
    get turf_monster_v1_path

    assert_response :success
    assert_match(/rounded to one decimal/i, rules_page_text,
                 "the printed formula must reproduce the paid multiplier")
  end

  # The scoring example's lead sentence is derived from the same data the table
  # renders, so it cannot name the wrong pair or quote a stale delta — which is
  # exactly what the hand-written version did.
  test "the scoring example lead matches the table it introduces" do
    get turf_monster_v1_path

    assert_response :success
    text = rules_page_text
    comparison = TurfMonsterRules.comparison

    assert_match(/#{comparison.fewer_points} fewer points/, text)
    assert_match(/#{Regexp.escape(format('%.1f', comparison.points_ahead))} ahead/, text)
    assert_match(/hypothetical/i, text,
                 "the invented weekly results must be hedged in the lead, not only under the table")
  end

  test "the World Cup rules page still answers" do
    get turf_totals_v1_path

    assert_response :success
  end

  # ── web3 onboarding guide ─────────────────────────────────────────────────

  test "getting started guide renders without auth with all five steps" do
    get getting_started_path
    assert_response :success
    assert_select "h1", "Getting Started"
    # The five steps, in order: Phantom → wallet → account → USDC → entry.
    assert_select "h2", /Download Phantom/
    assert_select "h2", /Create a new wallet/
    assert_select "h2", /Create your account/
    assert_select "h2", /Buy \$25 of USDC/
    assert_select "h2", /Sign in and enter a contest/
    # Official download link only — the guide must never point at a mirror.
    assert_select "a[href=?]", "https://phantom.com/download"
    # The operator's annotated walkthrough screenshots, one per setup beat.
    assert_select "section figure img[src*=?]", "guide/", minimum: 7
    # The fee expectation the operator verified: $25 purchase ≈ $20 after MoonPay fees.
    assert_match "MoonPay", response.body
    assert_match(/\$20 of USDC/, response.body)
    # Safety commitments: nobody asks for credentials; funnel into the app.
    assert_match(/never Turf Monster/i, response.body)
    assert_select "a[href=?]", signin_path
    assert_select "a[href=?]", proof_of_reserves_path
    assert_select "a[href=?]", responsible_gaming_path
  end

  test "state eligibility page renders the enforced Studio::GeoSetting list" do
    get state_eligibility_path
    assert_response :success
    assert_select "h1", /State Eligibility/
    # No Studio::GeoSetting row in fixtures → the page falls back to the defaults.
    Studio.geo_default_banned_subdivisions.each do |code|
      assert_match(">#{code}<", response.body, "expected default-excluded state #{code}")
    end
  end

  test "state eligibility page renders from the LIVE Studio::GeoSetting row (no drift)" do
    Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                       banned_subdivisions: %w[NY CA])
    get state_eligibility_path
    assert_response :success
    # The page must reflect the row enforcement reads — not a hardcoded list.
    assert_match "New York", response.body
    assert_match "California", response.body
    assert_no_match(/>WA</, response.body,
                    "a state absent from the live row must not be published")
  end

  test "terms page renders the anchored state-eligibility section from Studio::GeoSetting" do
    get terms_path
    assert_response :success
    assert_select "section#state-eligibility" do
      assert_select "h2", /State eligibility/
    end
    Studio.geo_default_banned_subdivisions.each do |code|
      assert_match(">#{code}<", response.body, "terms should list excluded state #{code}")
    end
  end

  test "terms page referral copy uses the corrected grammar" do
    get terms_path
    assert_response :success
    assert_match "every two qualifying invitees earn one free entry", response.body
    assert_no_match(/invitees earns/, response.body)
  end

  test "terms page carries the refund and cancellation policy" do
    get terms_path
    assert_response :success
    assert_select "section#refunds" do
      assert_select "h2", /Refunds/i
    end
    assert_match(/cancelled before it locks/i, response.body)
  end
end
