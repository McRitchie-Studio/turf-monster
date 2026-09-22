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
# speak for the other.
class SlatesFormulaPersistenceTest < ActionDispatch::IntegrationTest
  setup do
    @slate = slates(:one)
    @default_slate = Slate.create!(name: "Default")
    log_in_as(users(:alex))
  end

  test "every formula column round-trips through a slate save" do
    payload = assert_formula_columns_land(@slate) do |params|
      patch update_formula_slate_path(@slate), params: params
    end

    assert_redirected_to slate_path(@slate)
    assert_equal "Formula saved!", flash[:notice]
    assert_equal Slate::FORMULA_COLUMNS.size, payload.size
  end

  # Deriving from the constant covers an eighth column added TO THE CONSTANT.
  # It does NOT cover one added to the TABLE and permitted by hand while the
  # constant stays at seven — that column would simply fall outside every loop
  # above, and the file would stay green while covering less. This closes that
  # one remaining seam by pinning the constant to the schema.
  test "the constant the guard derives from covers every formula column on the table" do
    on_table = Slate.column_names.grep(/\Aformula_/).map(&:to_sym).sort

    assert_equal on_table, Slate::FORMULA_COLUMNS.map(&:to_sym).sort,
                 "Slate::FORMULA_COLUMNS has drifted from the slates table. Every assertion in this file " \
                 "derives its column list from that constant, so a formula column missing from it is a " \
                 "column NOTHING here covers — the exact gap this file was written to close."
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
  # Slate::FORMULA_COLUMNS actually landed on `record`. Returns the payload.
  def assert_formula_columns_land(record)
    payload = formula_payload
    ceiling = SlateMatchup::SLIDER_SCALES.max

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

    payload
  end
end
