require "test_helper"

# [component] The age-gate modal, after it stopped carrying its own copy of the
# date-of-birth selects.
#
# WHAT THIS IS DEFENDING. studio-engine 0.54 ships studio/fields/_date_of_birth —
# the engine's one DOB field — and it was extracted precisely because this app had
# forked a second copy of those three selects into app/views/modals/_age_verify.
# This app still owns the MODAL (it bakes in AgePolicy's per-state minimum and
# posts to /age/verify); it no longer owns the FIELD.
#
# THE HARD PART IS THAT THE FIX IS INVISIBLE IN THE OUTPUT. A forked copy and a
# shared render produce the same markup — that is what made the duplication
# survivable for so long — so a test that only renders cannot tell you which one
# it just rendered. This file therefore asserts two different kinds of thing, and
# is explicit about which is which:
#
#   · the RENDER, for "the field is really there and really wired"
#   · the SOURCE, for "there is exactly one copy of it"
#
# A source assertion is the weaker instrument and is used only where a rendered
# one provably cannot answer the question.
class AgeVerifySharedFieldTest < ActionView::TestCase
  FORK = Rails.root.join("app/views/modals/_age_verify.html.erb")

  # Returns THIS render's markup. ActionView::TestCase#rendered ACCUMULATES
  # across calls (the trap test/views/tokens_pack_button_test.rb documents), so
  # every refute below would pass vacuously off the union. Use the return value.
  def render_modal(geo_state: "NY")
    render partial: "modals/age_verify", locals: { geo_state: geo_state }
  end

  # --- the render: the shared field arrived, and arrived wired ----------------

  test "the modal renders all three date selects" do
    html = render_modal

    %w[month day year].each do |part|
      assert_match(/x-model="#{part}"/, html, "the #{part} select did not render")
    end
    assert_includes html, 'x-for="m in months"'
    assert_includes html, 'x-for="d in dayOptions"'
    assert_includes html, 'x-for="y in years"'
  end

  # THE FIELD'S UTILITIES MUST ACTUALLY BE COMPILED HERE, and how that is true
  # differs per app — which is worth being exact about, because the general
  # version of this rule does not apply to this one.
  #
  # The engine ships a PREBUILT bundle, so in a consumer that uses it a Tailwind
  # utility exists only if that consumer's own views already emitted it. That is
  # how the calendar popover this field replaced broke: it used grid-cols-7,
  # present in zero consumer bundles, and its seven weekday letters stacked into
  # a single vertical column.
  #
  # THIS APP IS THE EXCEPTION. It builds its OWN bundle and its content globs
  # include the engine's views (config/tailwind.config.js), so utilities the
  # engine uses are compiled here whether or not this app uses them. That one
  # glob is the entire reason, and it is one deletion away from turning this app
  # into the general case retroactively — every engine-only utility would vanish
  # from the bundle at once, with no error anywhere. So the glob is what is
  # pinned, rather than a build artifact this lane does not produce.
  test "this app's tailwind build still scans the engine's views" do
    html = render_modal
    assert_includes html, "grid-cols-3", "the field stopped using the utility this is about"

    config = Rails.root.join("config/tailwind.config.js").read
    assert_match(%r{\$\{studioPath\}/app/views/\*\*}, config,
                 "config/tailwind.config.js no longer scans the engine's views. Every utility " \
                 "the engine uses and this app does not — starting with this field's — would " \
                 "silently drop out of the compiled bundle, with nothing raising anywhere.")
    assert_match(/const studioPath = execSync\(['"]bundle show studio-engine['"]\)/, config,
                 "studioPath must resolve to the RESOLVED gem, so the scan follows the pin " \
                 "instead of a hardcoded version directory")
  end

  # THE APP-SPECIFIC HALF SURVIVED. Sharing the field must not have shared away
  # the per-state minimum or the endpoint — those are this app's, and the modal
  # is worthless without them.
  test "the modal still bakes in this app's own age policy and endpoint" do
    html = render_modal(geo_state: "IA")

    assert_includes html, "minAge: #{AgePolicy.minimum_age('IA')}"
    assert_includes html, "state: 'IA'"
    assert_includes html, "url: '#{age_verify_path}'"
    assert_includes html, "in IA", "the copy names the state the minimum came from"
  end

  # --- the equivalence the extraction rests on -------------------------------
  #
  # The shared field runs ONE on_change for all three selects. This app's day
  # select used `error = ''` and got `onMonthChange()` instead, and that swap is
  # only safe because of what THIS app's onMonthChange does — a property of this
  # app's component, not of the engine's field, so it is asserted here rather
  # than inherited from the engine's note.
  # NAMING THE HANDLER IS THE POINT, and this test did not at first — it asserted
  # only that the three AGREED, which a mutation walked straight through.
  # Rendering the field with `on_change: "error = ''"` keeps all three identical
  # and still breaks the modal: nothing clears an out-of-range day, so picking
  # March 31 and switching the month to February leaves 31 selected, `complete`
  # true, and an impossible date on its way to the server. Uniformity was a proxy
  # for correctness and it is not one.
  test "every select routes through the handler that clears an out-of-range day" do
    html = render_modal
    handlers = html.scan(/x-model="(month|day|year)"[^>]*@change="([^"]+)"/m).to_h { |k, v| [k, v] }

    assert_equal 3, handlers.size, "expected all three selects to declare a @change"
    assert_equal 1, handlers.values.uniq.size,
                 "the shared field gives all three selects the same hook; they differ: #{handlers}"
    assert_equal "onMonthChange()", handlers["month"],
                 "the month select must run the range-clearing handler — with anything else, " \
                 "March 31 → February keeps day 31 and submits an impossible date"
    assert_equal "onMonthChange()", handlers["year"],
                 "the year select must run it too: Feb 29 → a non-leap year has the same shape"
  end

  # THE HANDLER MUST CLEAR THE ERROR, because that is what the day select's old
  # binding did and all it did. If onMonthChange ever stops clearing it, the day
  # select silently regresses: a server error would persist after the user
  # changed the day it was about.
  test "the shared handler still clears the error the day select used to clear" do
    factories = Rails.root.join("app/views/shared/_alpine_factories.html.erb").read
    body = factories[/onMonthChange\(\)\s*\{(.*?)\n\s*\},/m, 1]

    assert body, "ageVerifyModal#onMonthChange is gone — the field's @change points at nothing"
    assert_match(/this\.error\s*=\s*""/, body,
                 "the day select's old binding was exactly `error = ''`; routing it through " \
                 "onMonthChange is only equivalent while onMonthChange still does this")
  end

  # AND MUST NOT CLEAR A VALID DAY. The other line in the handler blanks a day
  # left out of range by a month/year change. On the DAY select it must be inert,
  # because the day was just chosen from dayOptions — assert the guard is
  # conditional rather than an unconditional reset, which would make choosing a
  # day erase it.
  test "the shared handler only blanks a day that is out of range" do
    factories = Rails.root.join("app/views/shared/_alpine_factories.html.erb").read
    body = factories[/onMonthChange\(\)\s*\{(.*?)\n\s*\},/m, 1]

    assert_match(/if\s*\(.*dayOptions.*\)\s*this\.day\s*=\s*""/m, body,
                 "the day reset must stay guarded by the range check — unguarded, every day " \
                 "the user picks is immediately erased by its own @change")
  end

  # --- the source: exactly one copy ------------------------------------------
  #
  # THE ONLY QUESTION A RENDER CANNOT ANSWER. A re-forked copy renders
  # identically to the shared field, so the dedupe is asserted where the
  # difference actually exists.

  test "this app renders the engine's field instead of declaring its own selects" do
    source = FORK.read

    assert_includes source, 'render "studio/fields/date_of_birth"',
                     "the modal must render the engine's field"
    refute_match(/<select\b/, source,
                 "a <select> is back in this app's copy — the fork these two files spent a " \
                 "release removing has grown back. Add locals to the engine's field instead.")
    refute_match(/x-for="[mdy] in (months|dayOptions|years)"/, source,
                 "the field's option loops are back in this app's copy")
  end

  # The engine's field must be the one on disk, not a same-named host shadow.
  # A host view at app/views/studio/fields/_date_of_birth.html.erb would satisfy
  # every assertion above while being a third copy with extra steps.
  test "no host shadow of the engine's field" do
    shadow = Rails.root.join("app/views/studio/fields/_date_of_birth.html.erb")

    refute shadow.exist?,
           "this app shadows the engine's DOB field at #{shadow.relative_path_from(Rails.root)} — " \
           "that is the fork again, wearing the engine's path"
  end
end
