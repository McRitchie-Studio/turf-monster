require "test_helper"

# [component] What a connect failure SAYS.
#
# Production, 2026-09-06: the Phantom extension was installed but held no wallet
# — Phantom was sitting on its own "create a new wallet or import an existing
# one" screen. With no keypair, signIn() rejects with Phantom's generic
# "Unexpected error", the connect+signMessage fallback rejects the same way, and
# that string used to reach parseSolanaError — whose generic branch reads it as a
# TRANSACTION failure and answers "Wallet couldn't process the transaction. Check
# wallet connection and USDC balance."
#
# Balance advice, in a connect modal, to someone who attempted no transaction and
# may hold no wallet at all.
#
# AND THEN THE CATCH TURNED OUT TO BE WIDER THAN ITS DIAGNOSIS. It wrapped the
# whole fallback, so the same sentence was also handed to a signMessage that
# failed AFTER connect() returned a public key, to a user who dismissed the
# account-selection sheet, and to anyone whose only problem was that our own
# server did not answer. The setup diagnosis now belongs to exactly one case: a
# connect() that never answered.
#
# WHAT THIS TIER CAN AND CANNOT PROVE. Everything below reads SOURCE. It pins
# form and order — the mutations a substring check is blind to — and it is fast.
# It cannot say which guard actually answered a real failure. That is
# e2e/wallet_sign_in.spec.js, which runs the function and compares the sentences
# the page EMITTED against each other; three of its four specs fail on the code
# this change replaces. Do not read a green file here as behaviour.
class WalletConnectErrorCopyTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  MAPPER = Rails.root.join("app/javascript/solana_errors.js")
  MODAL  = Rails.root.join("app/views/modals/_wallet_setup.html.erb")
  PROVIDER = Rails.root.join("app/javascript/wallet_provider.js")

  test "a wallet that cannot answer gets setup copy, not balance advice" do
    src = LAYOUT.read

    assert_includes src, "Finish setting up your wallet in",
                    "a connect failure must be described as a connect failure"
    assert_includes src, "create or import one, then try again",
                    "and must name the action that actually unblocks the user"
  end

  test "a human who declines still reads as a rejection" do
    # A DECLINE IS NOT AN INCAPABILITY. Telling someone who just said no to
    # 'finish setting up your wallet' is its own wrong answer, so the rethrow
    # must let rejections past untouched.
    src = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]

    assert fallback, "the connect fallback block must still exist"
    assert_includes fallback, "user rejected"
    assert_includes fallback, "user declined"
    assert_includes fallback, "e.code === 4001"
    assert_match(/throw e;/, fallback, "a decline is rethrown unchanged")
  end

  test "a server or network failure is NOT diagnosed as a missing wallet" do
    src = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]

    # OUR OWN SERVER, KEPT OUT OF THE WALLET DIAGNOSIS — BY EVIDENCE, NOT BY
    # DISTANCE. noncePromise fetches /auth/solana/nonce. An offline moment must
    # never tell a user with a perfectly good wallet to "create or import one".
    #
    # #571 bought that by hoisting the await ABOVE the try, which also put a
    # server round trip ahead of the wallet sheet for every wallet without
    # solana:signIn. The rejection now carries a TAG instead, so the await can
    # sit back below connect() — where the fetch overlaps the human at the
    # prompt — and the catch can still tell the two apart.
    assert fallback, "the fallback block must exist"

    assert_includes src, "nonceFetchFailed = true",
                    "the nonce fetch's own rejection must be tagged at the source"

    guard_at   = fallback.index("if (e && e.nonceFetchFailed) throw e;")
    connect_at = fallback.index("var resp = await provider.connect();")
    nonce_at   = fallback.index("var data = await noncePromise;")

    assert guard_at, "the catch must rethrow a tagged nonce failure untouched"
    assert connect_at, "the fallback must still connect"
    assert nonce_at, "the fallback must still await the nonce"
    assert connect_at < nonce_at,
           "connect() must run BEFORE the nonce is awaited, so the fetch " \
           "overlaps the open wallet prompt instead of preceding it"
    assert guard_at > nonce_at,
           "the tagged-rejection guard belongs in the catch, after the await"
  end

  # --- the three guards, and the order they run in --------------------------

  test "the setup diagnosis is reachable only by a connect that never answered" do
    src      = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]

    # `connected` flips the instant connect() hands back a publicKey — at that
    # moment the wallet has PROVEN it holds a keypair. Assigning it any later
    # (after the nonce await, say) would leave a window in which a wallet that
    # already identified itself is still told to create one.
    pubkey_at    = fallback.index("pubkeyB58 = resp.publicKey.toBase58();")
    connected_at = fallback.index("connected = true;")
    nonce_at     = fallback.index("var data = await noncePromise;")

    assert pubkey_at && connected_at, "the connected flag must be set on success"
    assert pubkey_at < connected_at,
           "the flag records that a public key came back, so it follows it"
    assert connected_at < nonce_at,
           "and it must be set before ANY later await can reject"
  end

  test "the guards precede the setup copy, and only two rethrow untouched" do
    src      = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]
    throw_at = fallback.index(MESSAGE)

    assert throw_at, "the setup rethrow must exist"

    # Pinned verbatim, the way the decline guard already is: `!connected`,
    # `&&` for `||`, or a dropped tag check all read as PRESENT to a
    # substring assertion and change who gets the sentence.
    [
      "if (e && e.nonceFetchFailed) throw e;",
      "if (e && e.walletAnswered) throw e;"
    ].each do |guard|
      at = fallback.index(guard)
      assert at, "missing or altered guard: #{guard}"
      assert at < throw_at,
             "#{guard} must run BEFORE the setup message can be composed"
    end

    # THE CONNECTED GUARD DOES NOT RETHROW, and pinning it here as though it
    # did is what let the defect through a green file: `throw e` hands the
    # mapper Phantom's generic "Unexpected error", which its generic branch
    # rewrites into balance advice. So pin the SUBSTITUTION and its position,
    # and pin the old form as FORBIDDEN — restoring it must go red here.
    connected_at = fallback.index("if (connected) {")
    assert connected_at, "the connected guard must still exist, in braced form"
    assert connected_at < throw_at,
           "the connected guard must run BEFORE the setup message can be composed"
    refute_includes fallback, "if (connected) throw e;",
                    "rethrowing here gives the mapper the one string it mis-maps"
  end

  test "the wallet layer tags the rejections that prove a wallet exists" do
    src = PROVIDER.read

    # standard:connect resolving an EMPTY accounts array is a dismissed
    # account-selection sheet, not a missing wallet. Before this it reached the
    # fallback untagged and came back as "create or import one" — readable, and
    # false. Pinned verbatim: dropping the wrapper is invisible to a check that
    # only asks whether the message is still there.
    assert_includes src, "err.walletAnswered = true;",
                    "the tag helper must set the property the catch reads"
    assert_includes src, "throw _walletAnswered(new Error('No account authorized'));",
                    "an empty account list must carry the tag"
    assert_includes src, "Promise.reject(_walletAnswered(new Error('Wallet not connected')))",
                    "so must signing without a connected account"
  end

  test "the wallet is named the way its brand writes it, not by slug" do
    src = LAYOUT.read

    # provider.name is the lowercase slug on the legacy provider, so the sentence
    # read "your wallet in phantom". NOT asserting the label/displayName alternand:
    # nothing sets either key, so pinning its text certifies a dead branch.
    assert_includes src, "toUpperCase()",
                    "and capitalise the slug rather than printing it raw"
    refute_match(/in ' \+ \(\(provider && provider\.name\)/, src,
                 "the raw slug must not reach the sentence")
  end

  # --- killing the mutants a presence check cannot ---------------------------
  #
  # Review mutated this fix 12 ways and EIGHT survived: negating the decline
  # guard, || -> &&, throw -> console.warn, hoisting the throw above the guard,
  # commenting the throw out, dropping the /i, and poisoning the copy. Every one
  # survived because the tests asserted that text was PRESENT, and presence is
  # blind to form and order. These assert both.

  MESSAGE = "Finish setting up your wallet in "

  test "the decline guard keeps its exact form" do
    src = LAYOUT.read

    # Pinned verbatim: || -> && silently narrows the guard to declines that
    # satisfy BOTH patterns, i.e. none, and a presence check cannot see it.
    assert_includes src,
                    "if (/user rejected/i.test(em) || /user declined/i.test(em) || (e && e.code === 4001)) throw e;",
                    "negation, || -> &&, or a dropped /i must all fail here"
  end

  test "the guard runs BEFORE the rethrow, not after it" do
    src = LAYOUT.read
    guard_at = src.index("if (/user rejected/i.test(em)")
    throw_at = src.index(MESSAGE)

    # Hoisting the throw above the guard makes every decline read as a missing
    # wallet. Both lines still exist, so only their ORDER catches it.
    assert guard_at, "the guard must exist"
    assert throw_at, "the rethrow must exist"
    assert guard_at < throw_at,
           "a decline must be rethrown before the setup message can be composed"
  end

  test "the setup case throws rather than merely logging" do
    src = LAYOUT.read

    # throw -> console.warn leaves the string on the page and the user with
    # nothing: the picker renders whatever it caught, and it caught nothing.
    #
    # COMPOSED ONCE, INTO A NAME. The sentence stopped being an inline literal on
    # 2026-09-07: the report below needs the same string, and this file already
    # says why a second hardcoded copy is worse than none — a copy cannot fail
    # when the original changes. So the assertion follows the name instead of the
    # literal, and still refuses a message that is merely logged.
    assert_includes src, "var setupCopy = '#{MESSAGE}",
                    "the message must be composed once, into setupCopy"
    assert_includes src, "var setupError = new Error(setupCopy);",
                    "the error must be built from that one composition"
    assert_includes src, "throw setupError;",
                    "the message must be raised, not logged"
  end

  # --- the raw string, reported before it is destroyed -----------------------
  #
  # WHY THIS LIVES HERE. The substitution above is the only place in the app that
  # deliberately discards a wallet's error string, and until 2026-09-07 that made
  # report-client-wallet-failures capture our own sentence in BOTH halves for the
  # entire malfunction class — the class it was built for. What this tier can
  # prove is form and order. That the pair actually ARRIVES differing is
  # e2e/wallet_failure_report.spec.js.

  test "the wallet's own message is reported BEFORE the substitution replaces it" do
    src      = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]
    assert fallback, "the fallback block must exist"

    report_at = fallback.index("window.reportWalletFailure('connect_verify_fallback'")
    throw_at  = fallback.index("throw setupError;")

    assert report_at, "the fallback must report the failure it is about to relabel"
    assert throw_at, "the fallback must still throw"
    assert report_at < throw_at,
           "the report must be made while the wallet's own message still exists"
  end

  test "the reported raw half is the WALLET's message, not ours" do
    src = LAYOUT.read

    # THE WHOLE DEFECT, IN ONE ARGUMENT POSITION. `em` is what the wallet said;
    # `setupCopy` is what we replaced it with. Passing setupCopy as `raw` — or
    # swapping the pair — reproduces exactly the byte-identical row this change
    # removes, and every other assertion in this file stays green through it.
    assert_includes src,
                    "window.reportWalletFailure('connect_verify_fallback', brand, em, setupCopy);",
                    "raw must be the wallet's message and mapped must be ours, in that order"
  end

  test "the substituted error is tagged so no surface reports it a second time" do
    src = LAYOUT.read

    # Untagged, the wallet-setup modal reports the same failure again from its own
    # catch — and that second row carries our sentence in both halves, which is
    # the useless shape an operator would meet first.
    assert_includes src, "setupError.walletFailureReported = true;",
                    "the substituted error must carry the already-reported tag"
    assert_includes MODAL.read, "!(e && e.walletFailureReported)",
                    "the modal's catch must honour the tag"
  end

  # --- the SECOND substitution, held to the same three rules -----------------
  #
  # WHY THIS TRIO EXISTS SEPARATELY. The three tests above pin the setup-copy
  # substitution and pass whether or not any OTHER guard reports, which is how
  # the hole below opened: narrow-wallet-setup-diagnosis (#587) added a second
  # substituting guard — the `connected` branch — and every assertion above
  # stayed green while that branch handed a surface our sentence to put in both
  # halves. A per-site rule needs a per-site test; asserting the file "reports
  # somewhere" would have been blind to exactly this.
  #
  # The `connected` guard sits ABOVE the setup copy and returns first, so on a
  # wallet that connected and then failed to sign, the setup site never runs.

  SIGN_FAIL_MESSAGE = "Your wallet connected but could not sign you in."

  test "the connected-but-unsigned guard reports BEFORE it substitutes" do
    src      = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]
    assert fallback, "the fallback block must exist"

    report_at = fallback.index("window.reportWalletFailure('connect_verify_signature'")
    throw_at  = fallback.index("throw signFailError;")

    assert report_at, "the connected guard must report the failure it is about to relabel"
    assert throw_at, "the connected guard must still throw"
    assert report_at < throw_at,
           "the report must be made while the wallet's own message still exists"
  end

  test "the connected-but-unsigned guard reports the WALLET's message as raw" do
    src = LAYOUT.read

    # Same argument position, same defect if it is swapped. `em` is the wallet's
    # string — on this path Phantom's generic "Unexpected error" more often than
    # not — and `signFailCopy` is the sentence we hand the user instead.
    assert_includes src,
                    "window.reportWalletFailure('connect_verify_signature', brand, em, signFailCopy);",
                    "raw must be the wallet's message and mapped must be ours, in that order"
    assert_includes src, "var signFailCopy = '#{SIGN_FAIL_MESSAGE}",
                    "the message must be composed once, into signFailCopy"
  end

  test "the connected-but-unsigned error is tagged against a second report" do
    src = LAYOUT.read

    assert_includes src, "signFailError.walletFailureReported = true;",
                    "the substituted error must carry the already-reported tag"
  end

  test "brand is in hand before the FIRST guard that substitutes" do
    # THE ORDERING BUG THIS CATCHES. Both reports name the brand. `brand` used to
    # be computed below the `connected` guard, so moving a report up without
    # moving the composition would send `undefined` as the provider — a row that
    # survives (the server maps an unknown brand rather than refusing it) and
    # loses the field an operator filters on. Nothing else here would redden.
    src      = LAYOUT.read
    fallback = src[/if \(!useSignIn\) \{.*?\n          \}/m]
    assert fallback, "the fallback block must exist"

    brand_at = fallback.index("var brand = (provider && (provider.label")
    first_report_at = fallback.index("window.reportWalletFailure('connect_verify_signature'")

    assert brand_at, "the fallback must compose a brand"
    assert first_report_at, "the connected guard must report"
    assert brand_at < first_report_at,
           "brand must be composed before the first guard that reports it"
  end


  # --- the coupling this fix rests on ----------------------------------------

  test "the new message survives parseSolanaError untouched" do
    # The fix works ONLY because parseSolanaError passes unrecognised messages
    # through. If a future branch ever matches this wording, the picker would
    # silently show something else again — which is exactly the failure being
    # fixed, so pin it rather than assume it.
    # READ THE MESSAGE THE CODE ACTUALLY THROWS. A hardcoded copy of it cannot
    # fail when the copy changes, and that is the whole risk being guarded here:
    # edit the sentence to contain "insufficient funds" and the mapper rewrites
    # it straight back into the balance advice this task exists to remove.
    line = LAYOUT.read[/^\s*var setupCopy = 'Finish setting up.*$/]
    assert line, "the setup message must be composed as a one-line literal"
    message = line[/'(.*)';/, 1]
              .gsub("' + brand + '", "Phantom")
              .gsub('\\u2014', "\u2014")
    mapper  = MAPPER.read

    assert_includes mapper, "return msg;",
                    "the pass-through branch is what carries this message"

    # Every regex literal the mapper tests a message against.
    mapper.scan(%r{/((?:[^/\\\n]|\\.)+)/([im]*)\.test\(msg\)}).each do |body, flags|
      re = Regexp.new(body, flags.include?("i") ? Regexp::IGNORECASE : 0)
      refute_match re, message,
                   "parseSolanaError would rewrite the setup message via /#{body}/#{flags}"
    end
    refute_equal "Unexpected error", message
  end

  test "the signing message survives parseSolanaError untouched" do
    # THE SAME COUPLING THE SETUP MESSAGE RESTS ON, and the whole reason this
    # guard substitutes instead of rethrowing: a sentence the mapper rewrites
    # would put the transaction copy back onto a sign-in surface. Read what the
    # code actually composes — a hardcoded copy here could not fail when the
    # sentence changes, which is the risk being guarded.
    #
    # COMPOSED ONCE, LIKE setupCopy, since 2026-09-07. It used to be thrown as an
    # inline literal; the guard now REPORTS the wallet's own string before it
    # substitutes this one, so the sentence has to exist as a value the report
    # and the Error can both read. Same shape as the setup half above.
    line = LAYOUT.read[/^\s*var signFailCopy = 'Your wallet connected.*$/]
    assert line, "the signing message must be composed as a one-line literal"
    message = line[/'(.*)';/, 1].gsub('\\u2014', "\u2014")
    mapper  = MAPPER.read

    # Every regex literal the mapper tests a message against.
    mapper.scan(%r{/((?:[^/\\\n]|\\.)+)/([im]*)\.test\(msg\)}).each do |body, flags|
      re = Regexp.new(body, flags.include?("i") ? Regexp::IGNORECASE : 0)
      refute_match re, message,
                   "parseSolanaError would rewrite the signing message via /#{body}/#{flags}"
    end
    # The equality branch is not a regex, so the scan above cannot see it.
    refute_equal "Unexpected error", message

    refute_includes message, "USDC balance",
                    "the signing message must not repeat the advice it exists to replace"
  end

  test "the shared transaction wording is left alone for the paths that own it" do
    # The entry flows raise real transaction errors and their copy is correct.
    # This fix must not have widened its blast radius by editing the mapper.
    assert_includes MAPPER.read,
                    "Wallet couldn't process the transaction. Check wallet connection and USDC balance.",
                    "the generic transaction branch stays for the entry paths"
  end
end
