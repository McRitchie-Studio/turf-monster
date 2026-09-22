require "test_helper"

# [integration] POSITIVE CONTROL for the formula save paths. Its sibling,
# slates_formula_validation_test.rb, proves a BAD value is refused; nothing
# proved a GOOD one lands.
#
# WHY THIS EXISTS, measured 2026-09-21 at the review of PR 795: permitting only
# `:formula_mult_scale` in SlatesController#formula_params — instead of all of
# Slate::FORMULA_COLUMNS — left the FULL minitest suite green (1930 runs, 0
# failures). Six of the seven formula columns could stop persisting entirely and
# no minitest would notice. Exactly one column had a positive control, and only
# at the e2e tier: e2e/multi_week_slate.spec.js writes formula_mult_scale
# through the real admin form (:19) and reads it back (:153) — the slowest lane
# and the one a builder is least likely to run locally.
#
# THE LIST IS DERIVED, NOT TYPED. Every assertion below loops over
# Slate::FORMULA_COLUMNS, so an eighth column is covered the day it joins
# FORMULA_DEFAULTS rather than the day someone remembers this file. Hand-listing
# the seven would reproduce the exact bug this guards: a permit list and a test
# that each have to be updated by hand, and drift apart in silence.
#
# BOTH CALL SITES. `formula_params` feeds two actions — SlatesController
# #update_formula (a real slate) and #update_admin_formula (the "Default" row) —
# so both are exercised. A permit list is shared state; one green path does not
# speak for the other. Every GUARD the two paths share — including the assertion
# that the payload is the FULL constant — lives in #assert_formula_columns_land,
# so a guard cannot be satisfied on one path on behalf of the other.
# (#formula_payload and the setup block are shared too and sit outside it. The
# payload is the state the size guard exists to catch someone shrinking, so it
# is read by both paths and owned by neither.)
class SlatesFormulaPersistenceTest < ActionDispatch::IntegrationTest
  setup do
    @slate = slates(:one)
    @default_slate = Slate.create!(name: "Default")
    log_in_as(users(:alex))
  end

  test "every formula column round-trips through a slate save" do
    assert_formula_columns_land(@slate) do |params|
      patch update_formula_slate_path(@slate), params: params
    end

    assert_redirected_to slate_path(@slate)
    assert_equal "Formula saved!", flash[:notice]
  end

  # Deriving from the constant covers an eighth column added TO THE CONSTANT.
  # It does NOT cover one added to the TABLE and permitted by hand while the
  # constant stays at seven — that column would simply fall outside every loop
  # above, and the file would stay green while covering less.
  #
  # WHAT THIS PINS, stated exactly because it used to claim the whole seam: the
  # constant against the `formula_`-NAMED columns on the table. That is NARROWER
  # than the permit list the constant feeds, and the gap is real — measured
  # 2026-09-22, `params.permit(*FORMULA_COLUMNS, :week)` leaves this test GREEN
  # with zero coverage of the extra key, because neither the constant nor the
  # table changed. The test below pins the permit surface itself and reds on
  # exactly that mutation; this one pins the naming convention that surface
  # derives from. Neither claims the other's ground. (carl, at the review of
  # PR 801.)
  test "the constant the guard derives from covers every formula column on the table" do
    on_table = Slate.column_names.grep(/\Aformula_/).map(&:to_sym).sort

    assert_equal on_table, Slate::FORMULA_COLUMNS.map(&:to_sym).sort,
                 "Slate::FORMULA_COLUMNS has drifted from the slates table. Every assertion in this file " \
                 "derives its column list from that constant, so a formula column missing from it is a " \
                 "column NOTHING here covers — the exact gap this file was written to close."
  end

  # The companion to the schema pin above, and the one that actually watches the
  # permit list. SlatesController#formula_params is `params.permit(*Slate::
  # FORMULA_COLUMNS)` today, and a column hand-added there — `, :week` — is
  # invisible to every other assertion in this file: they all derive their column
  # list from the constant, so they would never post it and never miss it.
  #
  # PROBED, NOT READ. Feeding the permit list every column the slates table has
  # and seeing which survive measures the surface; grepping the controller would
  # only re-read its source.
  #
  # BOUND, stated so it is not mistaken for more: `permit` can be observed only
  # through keys it is FED, so this measures the permit surface over the SLATES
  # TABLE, and a permitted key that is not a column there stays invisible —
  # carl's own `:mult_ceiling` among them. That bound is deliberate rather than
  # leftover: an off-table key cannot under-cover SILENTLY, because assigning it
  # raises ActiveModel::UnknownAttributeError ("unknown attribute
  # 'mult_ceiling' for Slate.", measured 2026-09-22). The silent case is a REAL
  # column permitted by hand, and that is the case this covers.
  test "the formula permit list accepts the constant and nothing else on the table" do
    controller = SlatesController.new
    controller.params = ActionController::Parameters.new(Slate.column_names.index_with { "1" })

    permitted = controller.send(:formula_params).keys.sort

    assert_equal Slate::FORMULA_COLUMNS.map(&:to_s).sort, permitted,
                 "SlatesController#formula_params permits #{permitted.inspect}, which is not " \
                 "Slate::FORMULA_COLUMNS. A key permitted alongside the constant is posted by nothing " \
                 "in this file and therefore covered by nothing in this file."
  end

  test "every formula column round-trips through the default formula save" do
    assert_formula_columns_land(@default_slate) do |params|
      patch update_admin_formula_slates_path, params: params
    end

    assert_redirected_to admin_formula_slates_path
    assert_equal "Default formula saved!", flash[:notice]
  end

  private

  # One DISTINCT value per column, keyed off the constant's own order. Distinct
  # matters as much as non-default: equal values would still pass if the permit
  # list mapped column A's input onto column B, and a permutation is exactly the
  # kind of mistake a count cannot see.
  #
  # The band is deliberately small. `formula_mult_scale` is the one column with a
  # live bound (0..SlateMatchup::SLIDER_SCALES.max), and it is bounded on the
  # MODEL, so an out-of-band value here would come back as a validation refusal
  # that looks like a persistence bug. The guard below measures that rather than
  # trusting this comment.
  def formula_payload
    Slate::FORMULA_COLUMNS.each_with_index.to_h do |column, index|
      [column.to_s, (0.11 + (index * 0.13)).round(2).to_s]
    end
  end

  # Posts `payload` through the caller's block and asserts every column in
  # Slate::FORMULA_COLUMNS actually landed on `record`.
  #
  # THE SIZE ASSERTION LIVES HERE, and the placement is the point. It was once
  # written into the slate-save test alone, and measured 2026-09-22 at the review
  # of PR 801: a #formula_payload shrunk to three columns reddened THAT path
  # while the default-save path stayed GREEN covering 3 of 7 — the exact silent
  # under-coverage this file exists to close, left open on one of its two paths.
  # A guard that loops can be satisfied by one member on behalf of the others;
  # in the shared helper, neither path can be.
  def assert_formula_columns_land(record)
    payload = formula_payload
    ceiling = SlateMatchup::SLIDER_SCALES.max

    # Named for the record, so a two-path failure reads as two paths rather than
    # as one message printed twice.
    assert_equal Slate::FORMULA_COLUMNS.size, payload.size,
                 "the #{record.name.inspect} save path posted #{payload.size} of " \
                 "Slate::FORMULA_COLUMNS' #{Slate::FORMULA_COLUMNS.size} columns. #formula_payload has " \
                 "been shrunk, so every assertion below would pass while covering less than the " \
                 "constant they all derive from."

    payload.each do |column, value|
      # Self-defense, not decoration: if the list ever grows past the band, fail
      # HERE with a legible message instead of as a mystery validation error
      # attributed to whichever column happens to carry a bound.
      assert_includes 0.0..ceiling, value.to_f,
                      "test payload for #{column} (#{value}) is outside 0..#{ceiling} — widen the band " \
                      "in #formula_payload; a model bound would refuse the save and look like a lost column"

      # A test that posts what the row already holds proves nothing about the
      # write path. Assert the change is observable BEFORE making it.
      assert_not_equal value.to_f, record.public_send(column)&.to_f,
                       "#{column} already holds #{value} before the save — this assertion would pass " \
                       "even if nothing persisted"
    end

    yield payload

    record.reload

    payload.each do |column, value|
      actual = record.public_send(column)

      assert_not_nil actual,
                     "#{column} did not persist at all (posted #{value}, row holds nil). " \
                     "Is it missing from Slate::FORMULA_COLUMNS, or dropped by " \
                     "SlatesController#formula_params?"

      assert_in_delta value.to_f, actual, 1e-9,
                      "#{column} persisted the wrong value (posted #{value}, row holds #{actual.inspect}). " \
                      "A permit list that maps one column's input onto another looks exactly like this."
    end
  end
end
