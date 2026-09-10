require "test_helper"

# Regression — bug: the auth modal's credential controls painted DEAD whenever
# `props.submitting` was undefined (turf-adopts-wallet-credential-slot).
#
# THE MECHANISM. Alpine's x-bind rewrites an `undefined` result to "" whenever
# the bound expression contains a DOT:
#
#   c === void 0 && typeof n === "string" && n.match(/\./) && (c = "")
#     (alpine.js 3.16.1, vendored in studio-engine)
#
# "" is not in bindAttribute's [null, undefined, false] removal list, and
# `disabled` is a boolean attribute, so Alpine assigns the attribute's own NAME
# and emits disabled="disabled". No console error; the card just cannot be
# tapped. `null` skips the rewrite and takes the removal branch, which is why an
# explicit null and a missing key are NOT interchangeable.
#
# WHY HARDENING AND NOT ONLY CALL-SITE DISCIPLINE. UI_PATTERNS.md item 10 used to
# argue that passing every key at every opener was the whole defence, on the
# premise that "production was always correct" and only the /admin/modals gallery
# was short. That premise was measured false by two live paths:
#
#   1. app/javascript/solana_utils.js reopens this modal at the credentials step
#      after a 401. It passed { step: 'credentials' } and nothing else, so every
#      credential control rendered disabled for a user whose session had just
#      expired — the one moment the modal exists to serve.
#   2. The `props` getter in the partial returns an EMPTY OBJECT whenever
#      current() is transiently null during an open or close transition. There is
#      no call site on that path, so no amount of opener discipline reaches it.
#
# (1) is fixed at the opener AND here; (2) can only be fixed here. The gem's own
# copy of the wallet button (solana_studio/auth/_wallet_credential) coerces the
# same way, so hardening also converges the two rather than forking them.
#
# Measured in a browser against the vendored alpine.js before the fix: with props
# { step: 'credentials' }, `:disabled="props.submitting"` yielded button.disabled
# true and attribute disabled="disabled", while `:disabled="!!props.submitting"`
# yielded false. Same for a props value of {}.
# ONE MORE ASSERTION ARRIVED HERE on 2026-09-09, when
# test/controllers/auth_credentials_gallery_test.rb was retired with the
# /admin/modals/preview seam it drove. Three of that file's four tests died with
# their subject — two asserted the preview page round-tripped a null `submitting`
# into its config blob, and the third pinned a Ruby mirror of the
# isCredentialsStep getter that had lost its last reader. The fourth never
# depended on the preview at all: it reads the two live openers and requires them
# to agree. It is the call-site half of the pair this file's header describes, so
# it belongs beside the hardening half rather than in a file named after a
# showroom that no longer exists.
class AuthSubmittingCoercionTest < ActiveSupport::TestCase
  AUTH_PARTIAL = "app/views/modals/_auth.html.erb".freeze
  SOLANA_UTILS = "app/javascript/solana_utils.js".freeze

  # The two production openers of the CREDENTIALS card. Whatever these pass is
  # the shape every other opener owes; reading them rather than restating them
  # here means a key added to the live payload turns this red instead of quietly
  # widening the gap.
  LIVE_CALL_SITES = [
    "app/views/components/_user_nav.html.erb",
    "app/views/layouts/_navbar.html.erb"
  ].freeze

  # Comments are page content as far as a naive scan is concerned — the partial
  # DESCRIBES the coercion in prose a few lines above the markup that performs
  # it. Strip both comment syntaxes so every assertion below reads real markup.
  def markup_of(path)
    src = Rails.root.join(path).read
    stripped = src.gsub(/<%#.*?%>/m, "").gsub(/<!--.*?-->/m, "")

    # Prove the stripper left the thing under test standing. A greedy or
    # mis-anchored strip that ate the buttons would make every assertion below
    # pass by having nothing to disagree with.
    assert_includes stripped, "openWalletHub()",
                    "comment stripping removed the wallet button from #{path} — the scan below " \
                    "would be reading an empty file"
    assert_operator stripped.length, :>, (src.length * 0.4),
                    "comment stripping removed more than 60% of #{path}; the regexes have " \
                    "over-matched and the assertions below are not reading the partial"
    stripped
  end

  # ─── EACH CREDENTIAL CONTROL, READ ON ITS OWN OPEN TAG ─────────────────────
  #
  # A COUNT CANNOT SAY WHICH. The first test below used to prove the lock with a
  # page-wide sweep: no bare binding anywhere, and at least four coerced ones
  # somewhere. MEASURED 2026-09-10 against that version, by exit code, with the
  # partial mutated and the test untouched:
  #
  #   Google's :disabled MOVED onto the "or" divider              -> exit 0, GREEN
  #   a hidden span carrying the Solana anchor AND the lock,
  #   planted ahead of a Solana button stripped of its own        -> exit 0, GREEN
  #
  # Each leaves a credential button live while another credential is submitting,
  # and the suite reported the lock wired. Deleting a lock outright did go red,
  # but only because the count sat exactly on its floor of four: one more coerced
  # binding anywhere in the partial would have silenced that as well.
  #
  # PROVENANCE. The reader below is studio-engine's open_tag_containing and
  # credential_visibility_gate (test/integration/style_page_test.rb), written for
  # the style guide's auth SPECIMEN. Engine PR #319 retired that specimen, which
  # was the reader's only caller; this card is the real one it stood in for. Two
  # changes, both deliberate:
  #
  #   · THE ATTRIBUTE IS A PARAMETER. The specimen gated each credential with
  #     x-show="methodOn('…')". This card has no methodOn and no per-credential
  #     x-show — every method always renders — so its per-control contract is the
  #     busy lock, :disabled. The walk is unchanged; only what it reads moved.
  #   · IT IS A COPY, NOT A SHARED HELPER. Engine test files do not ship in the
  #     gem, so sharing would mean moving test support into the engine's lib/ —
  #     every consumer's production load path — and naming it from here under a
  #     two-segment `~> 0.73` pin, which cannot state the patch floor a brand-new
  #     constant would need. The copy with a live caller is the one worth keeping.

  # Each credential control, and the anchor that identifies it.
  #
  # ANCHORS ARE THE HANDLER BINDING, never the bare handler name — the rule the
  # engine learned first. This partial's x-data DEFINES loginGoogle() and
  # submitMagicLink() above the buttons, so each bare name occurs TWICE and the
  # first match lands inside the x-data's own attribute. MEASURED: the walk then
  # raises "closed BEFORE the anchor". Loud, but aimed at the wrong element. With
  # the binding, each anchor below occurs exactly once, and credential_gate's
  # count makes that a check rather than a comment.
  #
  # THE EMAIL LINK CONTROL IS THE SUBMIT BUTTON, NOT THE FORM. The handler binding
  # sits on the <form>, and a form carries no lock: MEASURED, reading :disabled off
  # `@submit.prevent="submitMagicLink()"` returns nil. The lock is on the partial's
  # one submit button, so that is the anchor.
  CREDENTIAL_CONTROLS = {
    "Google"     => /@click="loginGoogle\(\)"/,
    "Solana"     => /@click="openWalletHub\(\)"/,
    "Email Link" => /\stype="submit"/
  }.freeze

  # The fourth control, the email field, is not an open tag in this source. It is
  # an ERB render call, and the lock travels as its disabled_expr: argument, so
  # the tag reader cannot reach it. This binds the argument to the call instead:
  # `[^%]*` cannot cross the call's own `%>` (ERB ends the tag at the first one),
  # so the lock must sit on THIS render, not on another call in the partial. One
  # weakness, and it fails LOUD: an argument containing a literal "%" stops the
  # match early and reads as a missing lock.
  EMAIL_FIELD_CALL = %r{render "studio/modals/shared/email_field"}
  EMAIL_FIELD_LOCK = %r{render "studio/modals/shared/email_field",[^%]*disabled_expr:\s*"!!props\.submitting"}

  # A well-formed HTML OPEN TAG, whole. Attribute names are deliberately loose
  # (`@click`, `:disabled`, `x-show` are all legal here); values are the three
  # HTML shapes. An overrun window carries following markup, which cannot match.
  OPEN_TAG = %r{\A<[A-Za-z][^\s>/]*(?:\s+[^\s=>/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*))?)*\s*/?>\z}

  # The open tag of the element whose ATTRIBUTES contain `anchor`, from its "<"
  # to the ">" that closes it. Nil ONLY when the anchor is genuinely absent;
  # every other unhappy path raises, loudly, by name.
  #
  # The walk is quote-aware because Alpine expressions carry ">" freely (`=>`,
  # `count > 0`), and a naive index(">") truncates a tag at the first one inside
  # an attribute value. None of the three tags here carries one today, which is
  # exactly the kind of property a reader should not lean on.
  #
  # AND IT IS GUARDED. rindex("<") takes the NEAREST "<" before the anchor, which
  # is structurally the anchor's own tag's "<": an earlier "<" cannot be chosen
  # while a closer one exists. But when the nearest "<" sits INSIDE an attribute
  # value on the anchor's own tag, the walk starts mid-string with its quote state
  # inverted, and from there it can run off the end, close on a ">" before the
  # anchor, or sail past the real ">" and return kilobytes of following markup
  # while calling it an element. No ONE invariant catches every misaligned shape,
  # and each of the five catches a shape the others miss:
  #   · no "<" precedes the anchor at all                        (unwindowable)
  #   · an UNQUOTED "<" appeared before the ">"                  (state inverted)
  #   · the anchor is present but the walk found no closing ">"  (ran off the end)
  #   · the ">" it closed on precedes the anchor                 (wrong element)
  #   · the window is not a single well-formed open tag          (overrun)
  # The first self-test at the bottom of this file raises all five against
  # constructed markup. MEASURED on this copy rather than inherited: replace any
  # one raise with what a naive walk does instead (answer nil, or trust the
  # window) and its case comes back SILENT — nothing raised, a wrong answer.
  def open_tag_containing(source, anchor)
    source = source.to_s
    site = source.index(anchor)
    return nil unless site

    start = source.rindex("<", site)
    raise "open_tag_containing: misaligned — no \"<\" precedes the anchor" unless start

    element = nil
    quote = nil
    cursor = start
    while (cursor += 1) < source.length
      char = source[cursor]
      if quote
        quote = nil if char == quote
      elsif ['"', "'"].include?(char)
        quote = char
      elsif char == "<"
        raise "open_tag_containing: misaligned — an unquoted \"<\" appears before " \
              "the tag closed, so the walk's quote state is inverted"
      elsif char == ">"
        element = source[start..cursor]
        break
      end
    end

    raise "open_tag_containing: misaligned — the anchor is present but no tag " \
          "closed after it (the walk ran off the end)" unless element
    raise "open_tag_containing: misaligned — the tag closed BEFORE the anchor, " \
          "so this window is not the element carrying it" unless cursor > site
    raise "open_tag_containing: misaligned — the window is not a single open " \
          "tag (#{element.bytesize} bytes), so it overran the element" \
          unless element.match?(OPEN_TAG)

    element
  end

  # The expression `attribute` binds on the control `anchor` identifies, or nil
  # when that control carries no such attribute.
  #
  # EVERY invariant in open_tag_containing can be satisfied by the WRONG element.
  # `index` takes the FIRST match, and nothing there asks whether that match is a
  # LIVE control. A decoy earlier in the block (a hidden element, a <script>
  # string, an attribute value holding well-formed markup) windows to itself,
  # passes all five, and hands back ITS binding while the real control carries
  # none. That is the hidden-span decoy measured above, and it is why the anchor
  # must occur exactly ONCE. HTML comments never get this far, because markup_of
  # strips them first; the count covers every other place a decoy can live.
  def credential_gate(block, anchor, attribute)
    occurrences = block.to_s.scan(anchor).size
    if occurrences > 1
      raise "credential_gate: the anchor #{anchor.inspect} matches #{occurrences} " \
            "times in this block, so `index` cannot be trusted to have found the LIVE " \
            "control. A decoy (hidden element, script string, attribute value) would " \
            "window to itself and report a binding the real control does not carry. " \
            "Narrow the anchor or the block."
    end

    open_tag_containing(block, anchor)&.slice(/\s#{Regexp.escape(attribute)}="([^"]*)"/, 1)
  end

  test "every credential control coerces submitting rather than binding it bare" do
    markup = markup_of(AUTH_PARTIAL)

    # ABSENCE is a page-wide question, so a page-wide scan is the right tool for
    # it. Derived, not hard-coded: whatever binds `submitting` to `disabled` BARE
    # is in scope, so a fifth control added tomorrow is covered without editing
    # this.
    bare  = markup.scan(/:disabled="props\.submitting"/)
    bare += markup.scan(/disabled_expr:\s*"props\.submitting"/)

    assert_empty bare,
                 "#{AUTH_PARTIAL} still binds `submitting` to `disabled` through a BARE dotted " \
                 "expression. Alpine rewrites an undefined result to \"\", which SETS a boolean " \
                 "attribute — the control renders dead for any opener that omits the key, and " \
                 "for the empty-object props getter, which has no opener at all."

    # PRESENCE is not. Each control's lock is read off that control's own open tag;
    # the reader above records why a count could not do it. These also calibrate
    # the sweep: assert_empty would pass just as happily against a partial that
    # stopped binding disabled altogether, and these cannot.
    CREDENTIAL_CONTROLS.each do |control, anchor|
      lock = credential_gate(markup, anchor, ":disabled")
      refute_nil lock,
                 "the #{control} control carries no :disabled at all, so it stays live while " \
                 "another credential is submitting. This reads the #{control} control's OWN " \
                 "open tag; a lock that moved to another element does not count."
      # Strict on spelling, like the sweep above: this file's contract is the
      # coerced form. A different spelling means re-checking the header's Alpine
      # reasoning before this expectation moves.
      assert_equal "!!props.submitting", lock,
                   "the #{control} control's own lock is #{lock.inspect}, not the coerced " \
                   "!!props.submitting this file's header requires"
    end

    assert_equal 1, markup.scan(EMAIL_FIELD_CALL).size,
                 "expected exactly one email_field render in #{AUTH_PARTIAL}; the lock " \
                 "assertion below binds to that call and cannot choose between two"
    assert_match EMAIL_FIELD_LOCK, markup,
                 "the email field's own render call no longer passes " \
                 "disabled_expr: \"!!props.submitting\", so the field stays editable " \
                 "mid-submit (or the lock moved to another call, which does not count)"
  end

  # Keys of the object literal the given file hands to modals.open('auth', {...}).
  def live_keys(path)
    payload = Rails.root.join(path).read[/\$store\.modals\.open\('auth',\s*\{([^}]*)\}\)/m, 1]
    assert payload.present?,
           "#{path} no longer opens the auth modal with an inline object — this test reads the " \
           "live prop shape out of it, so it needs retuning alongside that call site"
    payload.scan(/(\w+)\s*:/).flatten.map(&:to_sym).sort
  end

  test "both live call sites open the credentials card with the same prop shape" do
    shapes = LIVE_CALL_SITES.to_h { |path| [path, live_keys(path)] }

    # Calibration, and it is not ceremony: two openers that BOTH stopped passing
    # `submitting` would agree perfectly with each other while reintroducing the
    # exact defect this file exists for. The agreement assertion cannot see that;
    # this can.
    assert_includes shapes.values.first, :submitting,
                    "neither live call site passes `submitting` any more — the agreement " \
                    "assertion below would then be satisfied by two equally broken openers"

    assert_equal shapes.values.first, shapes.values.last,
                 "the navbar and the user-nav open the same modal with different props " \
                 "(#{shapes.inspect}). A key one of them omits is a control the other renders " \
                 "live and this one renders dead."
  end

  test "the 401 reopen seeds submitting rather than omitting it" do
    src = Rails.root.join(SOLANA_UTILS).read.gsub(%r{//[^\n]*}, "")

    payload = src[/modals\.open\('auth',\s*\{(.*?)\}/m, 1]
    assert payload.present?,
           "#{SOLANA_UTILS} no longer reopens the auth modal with an inline object — this test " \
           "reads the prop shape out of that call, so it needs retuning alongside it"

    keys = payload.scan(/(\w+)\s*:/).flatten.map(&:to_sym)
    assert_includes keys, :step, "the reopen no longer names a step; this test is miscalibrated"
    assert_includes keys, :submitting,
                    "#{SOLANA_UTILS} reopens the credentials card without `submitting`. A session " \
                    "that just expired is exactly when this modal matters, and an omitted key " \
                    "renders every credential control disabled."
  end

  # ─── THE READER, EXERCISED ─────────────────────────────────────────────────
  # The real partial reaches none of these branches, so without the tests below
  # every guard in the reader is prose. A guard nothing can redden is prose.

  test "the control window refuses a misaligned start instead of overrunning" do
    solana = CREDENTIAL_CONTROLS.fetch("Solana")

    # 1. A decoy "<" inside an earlier attribute value leaves the walk's quote
    #    state inverted from its first character, and it runs off the end without
    #    ever closing a tag.
    ran_off = %(<button x-text="a < b" @click="openWalletHub()">x</button>) +
              %(<div>markup an overrun would swallow</div>)
    assert_includes assert_raises(RuntimeError) {
      open_tag_containing(ran_off, solana)
    }.message, "ran off the end"

    # 2. The decoy carries its own ">", so the walk closes BEFORE the anchor and
    #    returns a window that does not contain the thing it was asked about.
    closes_early = %(<button x-html="<b>" @click="openWalletHub()">x</button>)
    assert_includes assert_raises(RuntimeError) {
      open_tag_containing(closes_early, solana)
    }.message, "closed BEFORE the anchor"

    # 3. An odd quote re-flips the inverted state, so the walk meets a "<" while
    #    it believes it is outside every value. Two inputs, in this order:
    #    · the shape ONLY this check catches. A stray quote right after the anchor
    #      re-flips at once, and the next tag's "<" arrives bare. MEASURED with
    #      this raise removed: the walk closes on that tag's ">" and returns
    #      `<b" @click="openWalletHub()"" <s>`, which every other invariant
    #      accepts. Nothing else stands between it and a silent wrong window.
    #    · the engine's original, re-flipped by later TEXT. The overrun check
    #      would catch this one too, under its own name, so on its own it could
    #      not prove this check load-bearing.
    [
      %(<button title="a <b" @click="openWalletHub()"" <s>),
      %(<button title="a <b" @click="openWalletHub()">x</button><p>6" pipe</p><div>tail</div>)
    ].each do |reflips|
      assert_includes assert_raises(RuntimeError) {
        open_tag_containing(reflips, solana)
      }.message, "unquoted"
    end

    # 4. The control: the same tag WITHOUT a decoy windows to itself EXACTLY, so
    #    the guard rejects misalignment rather than rejecting the walk. This case
    #    exercises the overrun check's SUCCESS path and cannot redden it.
    aligned = %(<button x-text="a b" @click="openWalletHub()" :disabled="!!props.submitting">x</button>) +
              %(<div>markup</div>)
    assert_equal %(<button x-text="a b" @click="openWalletHub()" :disabled="!!props.submitting">),
                 open_tag_containing(aligned, solana)

    # 5. The overrun check. The walk starts at a bare "<" that is TEXT, not a tag,
    #    and closes on a later ">" that is also text, so its window passes every
    #    earlier invariant: a "<" precedes the anchor, no unquoted "<" follows, a
    #    tag "closed", and it closed AFTER the anchor. Only the shape check sees it.
    text_not_a_tag = %(<p>a < b and @click="openWalletHub()" is here > done</p>)
    assert_includes assert_raises(RuntimeError) {
      open_tag_containing(text_not_a_tag, solana)
    }.message, "not a single open tag"

    # 6. No "<" precedes the anchor at all, so there is no window to walk. Distinct
    #    from the ONE legitimate nil below: there the anchor is ABSENT and nil is
    #    the answer; here it is PRESENT and unwindowable, which must raise.
    no_tag_at_all = %(@click="openWalletHub()")
    assert_includes assert_raises(RuntimeError) {
      open_tag_containing(no_tag_at_all, solana)
    }.message, %(no "<" precedes the anchor)

    # A genuinely absent anchor is the ONE nil, and it is not an error.
    assert_nil open_tag_containing(%(<div>no anchor here</div>), solana)
  end

  # THE FALSE GREEN ALL FIVE INVARIANTS ALLOW. open_tag_containing validates the
  # SHAPE of the window it built; nothing there asks whether the anchor it indexed
  # is a LIVE control. This is the failure this lineage keeps producing: a check
  # that reports success about something other than the thing it names.
  test "a decoy carrying the anchor cannot answer for the real control" do
    solana = CREDENTIAL_CONTROLS.fetch("Solana")

    # The decoy is hidden and carries the lock. The REAL button below carries NO
    # :disabled, so a green here would be entirely false.
    decoyed = <<~HTML
      <span hidden @click="openWalletHub()" :disabled="!!props.submitting"></span>
      <button @click="openWalletHub()">Solana</button>
    HTML

    error = assert_raises(RuntimeError) do
      credential_gate(decoyed, solana, ":disabled")
    end
    assert_includes error.message, "matches 2 times",
                    "the guard must refuse on COUNT, before `index` picks a winner"

    # Proof the refusal is worth having: without the count check, the decoy
    # answers and the real control's MISSING lock reads as present.
    assert_equal "!!props.submitting",
                 open_tag_containing(decoyed, solana).slice(/\s:disabled="([^"]*)"/, 1),
                 "this is the false green the count check exists to prevent — the window " \
                 "resolves to the hidden SPAN and reports a lock the button does not carry"

    # And the guard must not fire on the honest single-anchor case.
    honest = %(<button @click="openWalletHub()" :disabled="!!props.submitting">Solana</button>)
    assert_equal "!!props.submitting", credential_gate(honest, solana, ":disabled"),
                 "one anchor, one control — the count check must be invisible here"
  end

  # The email field's lock is bound to its OWN render call, never to whichever
  # call in the partial happens to carry one.
  test "the email field lock cannot be answered by another render call" do
    elsewhere = <<~ERB
      <%= render "studio/modals/shared/email_field", name: nil, x_model: "email" %>
      <%= render "some/other_field", disabled_expr: "!!props.submitting" %>
    ERB
    refute_match EMAIL_FIELD_LOCK, elsewhere,
                 "`[^%]*` must stop at the field's own %>; crossing it lets a neighbour's " \
                 "lock answer for a field that carries none"

    own = %(<%= render "studio/modals/shared/email_field", name: nil, disabled_expr: "!!props.submitting" %>)
    assert_match EMAIL_FIELD_LOCK, own, "the honest case must still match"
  end
end
