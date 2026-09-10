require "test_helper"

# Guards the CLAIMS the error-interpreter's comments make about where the
# no_funding blocker sends a blocked player.
#
# WHY A TEST FOR COMMENTS. Solana::ErrorInterpreter is the seam where an
# on-chain / RPC failure becomes what a user is TOLD about their money. Three
# comments in the service, and two in its test, said the no_funding blocker
# means the board "opens Top Up Wallet". It does not, and had not for some
# time: the board answers no_funding through selectionBoard#showFundsNeeded,
# which routes to Get USDC (modals/_buy_usdc) or — for the USDC kill-switch
# audience — Buy an Entry Token (modals/_buy_entry_token). A comment naming the
# wrong remediation surface teaches the next reader the wrong money path, which
# is why this is pinned rather than left to review.
#
# WHAT THIS GUARD DOES AND DOES NOT CATCH, stated plainly so nobody trusts it
# further than it goes:
#
#   · The POSITIVE assertions are the enforcement, and they are PER SITE: the
#     service is sliced into its no_funding regions and each one must name the
#     dispatcher and BOTH real destinations on its own. The service must also
#     carry the two conditions under which Top Up Wallet would regain an
#     entrance (that one is file-wide, and says so). None of them can pass
#     vacuously: an empty or unread file, or a slice that read nothing, fails.
#   · The NEGATIVE assertions are exact needles, each proven below against the
#     historical sentence it was written to catch. They stop the SPECIFIC false
#     claims from returning verbatim. They will not catch an arbitrary new
#     paraphrase — the positive assertions and review are what cover that.
#
# This file is deliberately NOT among the files it scans: it quotes the defect
# on purpose, in PRE_FIX_SENTENCES, so the needles can be proven to bite.
class Solana::ErrorInterpreterClaimsTest < ActiveSupport::TestCase
  SERVICE_PATH = Rails.root.join("app/services/solana/error_interpreter.rb")
  SPEC_PATH    = Rails.root.join("test/services/solana/error_interpreter_test.rb")

  SCANNED = {
    "app/services/solana/error_interpreter.rb"       => SERVICE_PATH,
    "test/services/solana/error_interpreter_test.rb" => SPEC_PATH
  }.freeze

  # Ruby comments wrap, so a claim can straddle two lines ("(Top Up\n # Wallet,
  # Coinbase-forward)"). Rejoin comment continuations and squeeze whitespace so a
  # needle matches the SENTENCE rather than the line the author happened to break
  # it on. Without this, the wrapped site slips every needle silently.
  def flatten(source)
    source.gsub(/\n[ \t]*#[ \t]?/, " ").gsub(/\s+/, " ")
  end

  # The six sentences these files carried before this task, verbatim. Each
  # needle below is proven against them, so a needle that can never match
  # anything fails HERE instead of passing as a soundness claim it cannot keep.
  PRE_FIX_SENTENCES = [
    "# / token-only. Maps to the no_funding blocker → board opens Top Up Wallet.",
    "#   meaning \"the managed wallet can't cover the USDC entry fee → Top Up\":",
    "# Map BOTH to no_funding/web2 so the board opens the Top Up Wallet instead",
    "# managed USDC entry that underfunds maps to no_funding/web2 (Top Up\n      # Wallet, Coinbase-forward), NOT the web3 deposit/currency picker.",
    "test \"0x1772 in a web2 session maps to no_funding/web2 (Top Up Wallet), not the web3 deposit modal\" do",
    "# the board opens the Top Up Wallet instead of attempting a doomed on-chain entry."
  ].freeze

  FALSE_CLAIM_NEEDLES = [
    /\bopens\s+Top\s+Up\s+Wallet\b/i,
    /\bopens\s+the\s+Top\s+Up\s+Wallet\b/i,
    /entry fee → Top Up/i,
    /maps to no_funding\/web2 \(Top Up Wallet/i,
    /no_funding\/web2 \(Top Up Wallet\), not/i
  ].freeze

  # --- anti-vacuity controls -------------------------------------------------
  #
  # A source-scanning test is exit-blind: if the read returns "" (moved file,
  # wrong root, a rename) every refute_match below passes and the suite reports
  # green on a file it never opened. These two tests are the proof that the scan
  # reached real content, and they run before anything is concluded from it.

  test "CONTROL: the scan reads real, substantial content from both files" do
    SCANNED.each do |label, path|
      assert path.exist?, "#{label} must exist for this guard to mean anything"
      body = path.read
      assert_operator body.bytesize, :>, 2_000,
                      "#{label} read back #{body.bytesize} bytes — the scan did not reach the real file"
      assert_includes body, "no_funding",
                      "#{label} must contain the blocker reason this guard is about"
      assert_includes flatten(body), "no_funding",
                      "flatten() must not destroy the content it normalizes in #{label}"
    end
  end

  test "CONTROL: every false-claim needle matches at least one real historical sentence" do
    haystack = flatten(PRE_FIX_SENTENCES.join("\n"))
    FALSE_CLAIM_NEEDLES.each do |needle|
      assert_match needle, haystack,
                   "needle #{needle.inspect} matches none of the sentences it was written to catch — " \
                   "it is dead, and would claim a soundness it cannot deliver"
    end
    # And the control has a control: the needles must not match arbitrary prose,
    # or "matches something" would be worthless.
    FALSE_CLAIM_NEEDLES.each do |needle|
      refute_match needle, "The funds wall routes through showFundsNeeded to Get USDC.",
                   "needle #{needle.inspect} matches a correct sentence — it is too broad"
    end
  end

  # --- the claim guard -------------------------------------------------------

  test "neither file claims the no_funding blocker's destination is Top Up Wallet" do
    SCANNED.each do |label, path|
      flat = flatten(path.read)
      FALSE_CLAIM_NEEDLES.each do |needle|
        refute_match needle, flat,
                     "#{label} says the no_funding blocker leads to Top Up Wallet. It does not: the board " \
                     "answers no_funding through selectionBoard#showFundsNeeded, which routes to Get USDC " \
                     "(modals/_buy_usdc) or, for the USDC kill-switch audience, Buy an Entry Token " \
                     "(modals/_buy_entry_token)."
      end
    end
  end

  # --- per-site enforcement ---------------------------------------------------
  #
  # WHY SLICE RATHER THAN COUNT. This guard used to assert the dispatcher and
  # the destinations across the WHOLE FILE — `flat.scan("showFundsNeeded").size
  # >= 3` and four bare assert_includes — while its header claimed each SITE
  # named them. A whole-file total cannot see WHERE the mentions are, so it
  # bit only by luck of distribution. Measured on this file at the time:
  # "showFundsNeeded" was spread 1/1/1, so the floor happened to hold, but
  # "Get USDC" was spread 3/1/1 — sites 2 and 3 could BOTH drop it and the
  # total stayed 3 and stayed green. A floor also goes SLACK the moment a
  # fourth no_funding branch is added, because the new branch raises the total
  # it is measured against. Raising the floor is not the fix either: it is the
  # same whole-file total wearing a bigger number.
  #
  # So slice, and derive the slice count FROM THE SOURCE — a fourth branch is
  # then covered the day it lands, with no edit here.
  NO_FUNDING_ANCHOR = /reason: "no_funding"/

  # One region per no_funding site: everything from the end of the previous
  # site through this site's own `reason: "no_funding"`. That is the span a
  # reader consults when they land on that branch — its comment block and the
  # code it describes.
  def no_funding_sites(source)
    sites = []
    start = 0
    source.to_enum(:scan, NO_FUNDING_ANCHOR).each do
      cut = Regexp.last_match.end(0)
      sites << source[start...cut]
      start = cut
    end
    sites
  end

  test "every no_funding site names the dispatcher and BOTH destinations" do
    source = SERVICE_PATH.read
    sites = no_funding_sites(source)

    # Anti-vacuity, three ways: the slicer must find every anchor the file
    # holds, it must find at least the three branches that existed when this
    # was written, and no slice may be a stub. Without these, a slicer that
    # returned [] would satisfy every per-site assertion below by iterating
    # nothing — the exact failure this test exists to remove.
    assert_equal source.scan(NO_FUNDING_ANCHOR).size, sites.size,
                 "the slicer must produce one region per no_funding site in the file"
    assert_operator sites.size, :>=, 3,
                    "the service carried three no_funding branches when this guard was written — " \
                    "the no-entry-tokens raise, the web2 USDC pre-check / raw-0x1 backstop, and the " \
                    "web2 arm of 6002; finding fewer means the slice did not reach the real file"

    required = {
      "showFundsNeeded"         => "the ONE dispatcher that answers no_funding on the board",
      "Get USDC"                => "the destination for everyone but the kill-switch audience",
      "modals/_buy_usdc"        => "the file behind Get USDC",
      "Buy an Entry Token"      => "the destination for the USDC kill-switch audience",
      "modals/_buy_entry_token" => "the file behind Buy an Entry Token"
    }

    sites.each_with_index do |site, index|
      number = index + 1
      assert_operator site.length, :>, 200,
                      "no_funding site #{number} sliced to #{site.length} bytes — that is a stub, " \
                      "not a region, so nothing asserted about it would mean anything"
      flat = flatten(site)
      required.each do |needle, why|
        assert_includes flat, needle,
                        "no_funding site #{number} does not name #{needle} — #{why}. Every site owes " \
                        "the reader the whole path on its own; a mention at another site does not " \
                        "help someone reading this one."
      end
    end
  end

  test "the service names the CONDITIONS under which Top Up Wallet regains an entrance" do
    flat = flatten(SERVICE_PATH.read)
    # NAME THE CONDITION, NOT THE STATE. A flat "it does not open Top Up Wallet"
    # rots the day someone adds a caller; naming both closed doors tells the next
    # reader exactly what would reopen one.
    assert_includes flat, "showWalletTopup",
                    "the note must name the orphaned opener — the first of the two closed doors"
    assert_includes flat, "returnModal",
                    "the note must name the hub prop — the second of the two closed doors"
    assert_match(/regains an entrance/i, flat,
                 "the note must say what would CHANGE, not merely assert today's state")
  end

  test "the spec's web2 0x1772 case names the dispatcher rather than a modal it never opens" do
    flat = flatten(SPEC_PATH.read)
    assert_includes flat, "showFundsNeeded",
                    "the web2/0x1772 case and the funding-preflight note must name the dispatcher"
    assert_includes flat, "Get USDC",
                    "the spec must name the destination a blocked player actually lands on"
  end
end
