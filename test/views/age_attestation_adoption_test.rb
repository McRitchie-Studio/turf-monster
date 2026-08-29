require "test_helper"

# [component] The legal-age attestation checkbox, after this app stopped
# carrying its own copy of it.
#
# WHAT THIS REPLACED. turf-monster shipped app/views/shared/_age_attestation
# while studio-engine ships studio/modals/shared/_age_attestation. DIFFERENT
# paths, so this was never a shadow that Rails resolution would collapse on its
# own — it was a parallel COPY, rendered from three callsites, and the engine
# partial was simply never reached. The two drifted, and the app kept the worse
# half: the engine paragraph carries role="alert" and the turf copy did not, so
# on the three surfaces that actually ask for the attestation a screen-reader
# user who submitted without ticking the box got a visible error and NO
# announcement. Adopting the engine partial is what fixes that.
#
# THE ONE BEHAVIOURAL SEAM. The turf fork SELF-GATED on AppFlags.age_attestation?
# — the whole partial was wrapped in the flag, so with the flag off it rendered
# nothing. The engine partial deliberately does not self-gate (its own doc
# comment says so). Adoption therefore MOVES the flag check out of the partial
# and into the three callsites, and the failure mode of getting that wrong is
# silent: the checkbox markup ships inside an inert <template> on a page that
# looks correct, and the parked flag stops being parked.
class AgeAttestationAdoptionTest < ActionView::TestCase
  DELETED_FORK = Rails.root.join("app/views/shared/_age_attestation.html.erb")
  APP_VIEWS    = Rails.root.join("app/views").to_s

  # ActionView::TestCase#rendered ACCUMULATES across render calls in one test,
  # so every refutation below would pass vacuously off the union. Use the
  # return value, always.
  def render_attestation(**locals)
    render partial: "studio/modals/shared/age_attestation", locals: locals
  end

  def fragment(html)
    Nokogiri::HTML5.fragment(html)
  end

  # The paragraph that x-shows on the error flag — located BY ITS BINDING, not
  # by position or class. "role=alert exists somewhere in this markup" is
  # satisfied by the attribute landing on the wrong element, which is the whole
  # reason this is a DOM assertion and not an assert_includes.
  def error_paragraph(html, error_model: "ageError")
    fragment(html).css(%(p[x-show="#{error_model}"]))
  end

  # --- the checkbox is the engine's -------------------------------------------

  test "the local fork is gone from disk" do
    # A render assertion cannot answer this: a fork and a shared render produce
    # near-identical markup, which is exactly how the copy survived unnoticed.
    assert_not File.exist?(DELETED_FORK),
      "#{DELETED_FORK.basename} is back — studio-engine owns this checkbox now"
  end

  test "the attestation partial resolves OUTSIDE this app" do
    # Assert by RESOLUTION, not by reading a render path out of a template:
    # `render \"studio/modals/…\"` still resolves to an app file if someone
    # re-forks it under that name, and the page looks identical when they do.
    #
    # Deliberately NOT asserting the identifier contains "/gems/" — that would
    # encode how the engine HAPPENS to be installed here and could never pass in
    # studio-engine's own consumer-CI lane, which bundles the engine as a path
    # checkout. "not inside app/views" is the property that actually matters.
    template = lookup_context.find("age_attestation", ["studio/modals/shared"], true)

    assert_not template.identifier.start_with?(APP_VIEWS),
      "the attestation must resolve to the engine, not to #{template.identifier}"
  end

  # --- the accessibility divergence the fork was holding ----------------------

  test "the error line is a live region on the paragraph that shows it" do
    paragraphs = error_paragraph(render_attestation)

    assert_equal 1, paragraphs.size,
      "expected exactly one paragraph bound to the error flag"
    assert_equal "alert", paragraphs.first["role"],
      "the attestation error must announce itself — a screen-reader user who " \
      "submits without ticking the box otherwise gets no feedback at all"
    assert_includes paragraphs.first.text, "legal age",
      "the live region must carry the error copy, not be an empty announcer"
  end

  test "the live region tracks a caller-supplied error model" do
    # Guards the role landing on a HARDCODED x-show="ageError" paragraph while
    # the real, caller-bound one goes unannounced.
    html = render_attestation(x_model: "okAge", error_model: "okAgeError")

    assert_empty error_paragraph(html),
      "the default error model must not survive an override"
    announced = error_paragraph(html, error_model: "okAgeError")
    assert_equal 1, announced.size
    assert_equal "alert", announced.first["role"]
  end

  # --- the seam the e2e suite selects on --------------------------------------

  test "the playwright hook survives the swap" do
    # e2e/helpers.js attestAge() selects input[data-age-attestation]. The engine
    # partial kept the attribute but dropped the comment that said why, so this
    # test is now the only thing standing between a markup tidy-up and five
    # silently-skipping e2e specs (attestAge no-ops when it finds no box).
    box = fragment(render_attestation).at_css("input[data-age-attestation]")

    assert box, "e2e/helpers.js attestAge() selects this attribute"
    assert_equal "checkbox", box["type"]
    assert_equal "ageAttested", box["x-model"]
  end

  # --- the flag check moved OUT of the partial and INTO the callsites ---------

  test "the engine partial does not self-gate on the parked flag" do
    # The property that makes the callsite gates load-bearing. If the engine
    # ever grows a self-gate, the callsite wrappers become dead code and the
    # next person deletes them.
    with_attestation_flag(false) do
      assert_not_empty render_attestation.strip,
        "the engine partial renders regardless of AppFlags — the CALLSITES gate"
    end
  end

  test "the wallet picker gates its attestation on the flag" do
    # The callsite that had no ERB flag check of its own: it relied on the
    # deleted fork's self-gate plus a client-side needsAttestation getter. A
    # <template> body is rendered SERVER-SIDE whether or not Alpine mounts it,
    # so without this gate the parked checkbox ships in the page source of
    # every layout that carries the picker.
    with_attestation_flag(false) do
      assert_not_includes render_wallet_picker, "data-age-attestation",
        "flag off: the picker must ship no attestation markup at all"
    end
    with_attestation_flag(true) do
      assert_includes render_wallet_picker, "data-age-attestation",
        "flag on: the picker must render the engine checkbox"
    end
  end

  private

  def render_wallet_picker
    render partial: "modals/wallet_connect"
  end

  def with_attestation_flag(on)
    previous = ENV["ENABLE_AGE_ATTESTATION"]
    ENV["ENABLE_AGE_ATTESTATION"] = on ? "true" : nil
    yield
  ensure
    ENV["ENABLE_AGE_ATTESTATION"] = previous
  end
end
