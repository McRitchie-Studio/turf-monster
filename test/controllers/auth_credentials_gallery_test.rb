require "test_helper"

# The auth CREDENTIALS card as /admin/modals previews it.
#
# COMPONENT tier: it drives the gallery's own preview route and asserts what a
# reviewer standing in front of the card would get.
#
# WHY THIS FILE EXISTS. The gallery painted the Credentials card with its
# Google, Solana and Email Link buttons — and the email field — all DISABLED,
# while production painted them live. Nothing was wrong with the modal: the
# variant's props simply left `submitting` out, and the four controls bind the
# bare dotted expression :disabled="props.submitting".
#
# THE MECHANISM, because the obvious reading of it is wrong. It is NOT that
# Alpine treats a missing key differently inside bindAttribute — there,
# `undefined` and `null` are both in the [null, undefined, false] removal list
# and behave identically. The divergence happens one step EARLIER, in x-bind:
#
#   c === void 0 && typeof n === "string" && n.match(/\./) && (c = "")
#     (alpine.js 3.16.1, vendored in studio-engine)
#
# An `undefined` result is rewritten to "" whenever the expression contains a
# DOT. "" is not in the removal list, and `disabled` is a boolean attribute, so
# Alpine assigns the attribute's own NAME and emits disabled="disabled". An
# explicit `null` skips that rewrite and takes the removal branch.
#
# So the assertions below are about PROPS, not markup, on purpose: the disabled
# attribute is applied by Alpine at runtime and never appears in the server's
# HTML. The rendered ERB is byte-identical whether the card is live or dead —
# which is exactly why this shipped unnoticed, and why a markup assertion here
# would be inert.
class AuthCredentialsGalleryTest < ActionDispatch::IntegrationTest
  # The two production call sites. Whatever THESE pass is the shape the gallery
  # owes; reading them rather than restating them means a key added to the live
  # payload turns this test red instead of quietly widening the gap.
  LIVE_CALL_SITES = [
    "app/views/components/_user_nav.html.erb",
    "app/views/layouts/_navbar.html.erb"
  ].freeze

  AUTH_PARTIAL = "app/views/modals/_auth.html.erb".freeze

  # Steps whose card is NOT the credentials step. Mirrors the isCredentialsStep
  # getter in _auth.html.erb; the last test in this file pins the two together.
  NON_CREDENTIALS_STEPS = %w[redirect magic-link-sent magic-link-resent].freeze

  def source(path)
    Rails.root.join(path).read
  end

  # Keys of the object literal the given file hands to modals.open('auth', {...})
  # for the CREDENTIALS step.
  def live_keys(path)
    payload = source(path)[/\$store\.modals\.open\('auth',\s*\{([^}]*)\}\)/m, 1]
    assert payload.present?,
           "#{path} no longer opens the auth modal with an inline object — this test reads the " \
           "live prop shape out of it, so it needs updating alongside that call site"
    payload.scan(/(\w+)\s*:/).flatten.map(&:to_sym).sort
  end

  def auth_variants
    AdminController::MODAL_VARIANTS.select { |v| v[:modal_id] == "auth" }
  end

  # The variants whose card actually renders the credential CTAs.
  def credentials_variants
    auth_variants.select do |v|
      step = v[:props][:step].to_s
      step.blank? || (NON_CREDENTIALS_STEPS.exclude?(step) && !step.start_with?("tokens-"))
    end
  end

  # --- the shape the gallery owes --------------------------------------------

  test "both live call sites open the credentials card with the same prop shape" do
    shapes = LIVE_CALL_SITES.to_h { |p| [p, live_keys(p)] }
    assert_equal shapes.values.first, shapes.values.last,
                 "the navbar and the user-nav open the same modal with different props " \
                 "(#{shapes.inspect}) — the gallery cannot mirror two shapes, so reconcile " \
                 "them before deciding what the preview should pass"
  end

  test "every credentials variant passes every key the live call sites pass" do
    expected = live_keys(LIVE_CALL_SITES.first)
    # Guard the guard: if the payload ever stops carrying submitting, the loop
    # below would pass vacuously against the very key this file exists for.
    assert_includes expected, :submitting,
                    "the live call site no longer passes `submitting` — this whole file is " \
                    "calibrated against that key"

    assert credentials_variants.any?, "no credentials-step auth variants found"
    credentials_variants.each do |v|
      missing = expected - v[:props].keys
      assert_empty missing,
                   "gallery variant #{v[:key].inspect} omits #{missing.inspect}, which the live " \
                   "callers pass. A key the preview leaves out is not a shorthand: a bare dotted " \
                   "bind on a boolean attribute renders `disabled` for an undefined prop, so the " \
                   "card reviews as dead while production is live."
    end
  end

  # The general rule, derived from the partial rather than from a list here: any
  # BARE dotted prop bound to a boolean attribute must be defined by every
  # variant that renders it. A `:disabled="props.foo"` added tomorrow brings
  # `foo` into this assertion automatically.
  #
  # RETUNED (turf-adopts-wallet-credential-slot) rather than deleted, exactly as
  # the previous calibration guard here asked. `submitting` is no longer bare:
  # all four credential controls now bind `!!props.submitting`, because call-site
  # discipline alone could never close the hole. The `props` getter in
  # #{AUTH_PARTIAL} returns an EMPTY OBJECT whenever current() is transiently
  # null during an open or close transition, and no opener exists to seed a key
  # on that path. So the rule below still stands for any bare bind, and the
  # calibration moves to the coerced form.
  BOOLEAN_ATTRS = %w[disabled checked readonly required selected multiple autofocus].freeze

  test "every bare dotted prop bound to a boolean attribute is defined by the credentials variants" do
    erb = source(AUTH_PARTIAL)
    bound = erb.scan(/:(#{BOOLEAN_ATTRS.join('|')})="props\.(\w+)"/).map { |_attr, key| key.to_sym }
    # ...including the ones handed to a shared field partial as an expression.
    bound += erb.scan(/disabled_expr:\s*"props\.(\w+)"/).flatten.map(&:to_sym)
    bound = bound.uniq

    # Guard the guard, retuned to the hardened shape: the scan must still be
    # READING the partial. If `submitting` stops appearing in the coerced form
    # too, this file has drifted off the control it was built for and the loop
    # below would pass vacuously.
    coerced = erb.scan(/:(?:#{BOOLEAN_ATTRS.join('|')})="!!props\.(\w+)"/).flatten.map(&:to_sym)
    coerced += erb.scan(/disabled_expr:\s*"!!props\.(\w+)"/).flatten.map(&:to_sym)
    assert_includes coerced.uniq, :submitting,
                    "#{AUTH_PARTIAL} no longer binds `submitting` to a boolean attribute in " \
                    "either the bare or the coerced form — retune this test to the new shape " \
                    "rather than deleting it"

    credentials_variants.each do |v|
      bound.each do |key|
        assert v[:props].key?(key),
               "variant #{v[:key].inspect} leaves `#{key}` undefined while #{AUTH_PARTIAL} binds " \
               "it to a boolean attribute through a dotted expression — Alpine rewrites the " \
               "undefined to \"\" and SETS the attribute, so the control renders dead"
      end
    end
  end

  # --- the delivery path ------------------------------------------------------

  # `submitting: nil` only helps if it survives Ruby -> query string -> JSON.parse
  # -> the JSON blob the harness reads. A serializer that drops nils (or a
  # refactor to to_query) would leave the key absent again with every assertion
  # above still green, so the round trip gets its own test.
  test "an explicit null submitting survives the round trip into the preview page" do
    variant = credentials_variants.find { |v| v[:key] == "auth-credentials" }
    assert variant, "the auth-credentials variant is gone"

    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "auth", props: variant[:props].to_json)
    assert_response :success

    config = preview_config
    assert config.key?("submitting"),
           "the preview page's config blob has no `submitting` key — it was dropped somewhere " \
           "between MODAL_VARIANTS and the JSON the harness reads, which is the original defect"
    assert_nil config["submitting"],
               "`submitting` reached the page as #{config['submitting'].inspect} rather than null"
  end

  # NEGATIVE CONTROL for the test above. The assertion has to be able to FAIL,
  # and the way it failed for real was a props hash with the key left out. Same
  # route, same reader, pre-fix input: the key must be absent. Without this, a
  # reader that silently returned a default-filled hash would let the test above
  # pass against the broken shape.
  test "the round-trip reader reports the key ABSENT for the pre-fix props" do
    log_in_as users(:alex)
    pre_fix = { mode: "signup", step: "credentials" }
    get admin_modal_preview_path(modal_id: "auth", props: pre_fix.to_json)
    assert_response :success

    config = preview_config
    assert_equal %w[mode step], config.keys.sort,
                 "the preview no longer round-trips exactly what it was given, so the test above " \
                 "is not measuring what it claims to"
    assert_not config.key?("submitting"),
               "the pre-fix shape came back WITH a submitting key — the reader is filling in " \
               "defaults, which would make the positive test vacuous"
  end

  def preview_config
    blob = Nokogiri::HTML(response.body).at_css("#modal-preview-config")
    assert blob, "no #modal-preview-config blob on the preview page"
    JSON.parse(blob.text)["props"]
  end

  # --- keeping this file honest ----------------------------------------------

  # credentials_variants above reimplements isCredentialsStep in Ruby. If the
  # getter learns a new excluded step, this file would keep asserting against
  # cards that no longer render the CTAs — silently over-scoped rather than red.
  test "the excluded steps match the isCredentialsStep getter" do
    getter = source(AUTH_PARTIAL)[/get isCredentialsStep\(\) \{(.*?)\n       \}/m, 1]
    assert getter.present?, "could not find the isCredentialsStep getter in #{AUTH_PARTIAL}"
    excluded = getter.scan(/s === '([^']+)'/).flatten.sort
    assert_equal NON_CREDENTIALS_STEPS.sort, excluded,
                 "isCredentialsStep now excludes #{excluded.inspect}; update " \
                 "NON_CREDENTIALS_STEPS so this file scopes to the cards that really render " \
                 "the credential CTAs"
    assert_includes getter, "tokens-",
                    "the getter no longer excludes the tokens-* steps that credentials_variants " \
                    "still filters out"
  end
end
