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
class AuthSubmittingCoercionTest < ActiveSupport::TestCase
  AUTH_PARTIAL = "app/views/modals/_auth.html.erb".freeze
  SOLANA_UTILS = "app/javascript/solana_utils.js".freeze

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

  test "every credential control coerces submitting rather than binding it bare" do
    markup = markup_of(AUTH_PARTIAL)

    # Derived, not hard-coded: whatever binds `submitting` to `disabled` is in
    # scope, so a fifth control added tomorrow is covered without editing this.
    bare    = markup.scan(/:disabled="props\.submitting"/)
    bare   += markup.scan(/disabled_expr:\s*"props\.submitting"/)
    coerced = markup.scan(/:disabled="!!props\.submitting"/)
    coerced += markup.scan(/disabled_expr:\s*"!!props\.submitting"/)

    assert_empty bare,
                 "#{AUTH_PARTIAL} still binds `submitting` to `disabled` through a BARE dotted " \
                 "expression. Alpine rewrites an undefined result to \"\", which SETS a boolean " \
                 "attribute — the control renders dead for any opener that omits the key, and " \
                 "for the empty-object props getter, which has no opener at all."

    # Calibration: the control must still EXIST. Without this the assert_empty
    # above would pass just as happily against a partial that stopped binding
    # disabled altogether.
    assert_operator coerced.length, :>=, 4,
                    "expected at least the four credential controls (Google, Solana, email " \
                    "field, Email Link) to bind !!props.submitting in #{AUTH_PARTIAL}; found " \
                    "#{coerced.length}"
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
end
