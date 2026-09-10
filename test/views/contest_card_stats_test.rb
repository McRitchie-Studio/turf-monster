# frozen_string_literal: true

require "test_helper"

# [component] THE CONTEST CARD'S MONEY LINE, and the hover response that goes
# with a live card.
#
# Five separately breakable claims, each of which reads plausibly when it is
# wrong, which is why each gets its own falsifier:
#
#   ORDER      prizes, then spots left, then entry — what is on offer, how much
#              room is left, what it costs. Asserted as a SEQUENCE read off the
#              rendered line, not as three independent "is it present" probes:
#              every one of those passes on the order this replaced.
#
#   SPOTS      the number is capacity MINUS the confirmed field, not the field.
#              The card is handed the field size (@entry_counts) and the two
#              numbers are one subtraction apart, so a card wired to the wrong
#              end of it renders a number, reads fine, and is about the opposite
#              fact. The fixture keeps them far apart (29-cap contest holding 2
#              entries → 27 left vs 2 taken) and both are named below.
#
#   CENTS      a whole-dollar figure drops its ".00" and a fractional one does
#              NOT. Asserted as a pair — `"$500"` alone matches inside
#              `"$500.00"`, so the positive half cannot fail on its own.
#
#   HOVER      a live card carries the lift, a coming-soon card does not. Both
#              halves, on the same page: a card that always carried it would
#              satisfy the positive assertion by itself.
#
#   FIZZ       the bubble layer is a direct child of the `.hold-stack` wrapper
#              and NOT inside the card. Both halves again, and the second is the
#              one that bites: a layer nested in the overflow-hidden card
#              renders, runs, and is invisible, so "it is present" is exactly
#              the assertion that cannot tell the working build from the broken
#              one.
#
# The money line is addressed through `data-contest-money-line`, not through its
# utility classes. `flex`/`text-sm` are not contracts; the seam is.
class ContestCardStatsTest < ActionDispatch::IntegrationTest
  MONEY = "[data-contest-money-line]"

  setup do
    @alex    = users(:alex)
    @contest = contests(:one)   # 29-cap, $19 entry, standard payouts ($500 pool)
  end

  def card_for(contest)
    "[data-contest-card='#{contest.slug}']"
  end

  # The rail wrapper around one card — the engine `.hold-stack` the fizz layer
  # is positioned against, and where the card's width is declared.
  def stack_for(contest)
    "[data-contest-stack='#{contest.slug}']"
  end

  # The rendered money line as one whitespace-collapsed string.
  def money_line_for(contest)
    element = css_select("#{card_for(contest)} #{MONEY}").first
    assert element, "the card must render a money line"
    element.text.squish
  end

  # --- order -------------------------------------------------------------

  # Read as a sequence. Each figure is matched with its own label attached, so
  # a build that kept the three figures and shuffled their labels fails here
  # too — "$19 prizes" is a different string from "$19 entry".
  test "[component] the money line reads prizes, then spots left, then entry" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_match(/\$500\s*prizes\s*\|\s*27\s*spots left\s*\|\s*\$19\s*entry/,
      money_line_for(@contest),
      "the money line must run prizes -> spots left -> entry")
  end

  # The prize is the only green figure on the card, and it is bold — the same
  # hierarchy the contest page's own stats row uses. Asserted on the element
  # CARRYING THE NUMBER, so a green label beside a plain number does not pass.
  test "[component] the prize amount is the card's one bold green figure" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)} #{MONEY} span.text-primary.font-extrabold",
      count: 1, text: "$500"
  end

  # --- spots left --------------------------------------------------------

  test "[component] the field's remaining spots are counted down from capacity" do
    log_in_as(@alex)

    # Stated rather than assumed: the two numbers must differ, or a card wired
    # to the field size would pass this test unchanged.
    assert_equal 29, @contest.max_entries
    assert_equal 2, Entry.confirmed.where(contest: @contest).count

    get contests_path

    assert_response :success
    line = money_line_for(@contest)
    assert_match(/\b27 spots left\b/, line)
    assert_no_match(/\bentries\b/, line,
      "the card reports room left, not the field size it was handed")
  end

  # An over-filled field (comped entries can push the count past the cap) reads
  # "0 spots left", never a negative one.
  test "[component] an over-filled field reads zero spots, not a negative count" do
    @contest.update!(max_entries: 1)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_match(/\b0 spots left\b/, money_line_for(@contest))
  end

  # --- cents -------------------------------------------------------------

  test "[component] whole-dollar figures drop their trailing cents" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    line = money_line_for(@contest)
    assert_match(/\$500 prizes/, line)
    assert_match(/\$19 entry/, line)
    assert_no_match(/\$\d+\.00/, line, "a whole-dollar figure must not print .00")
  end

  # The zero is what is noise, not the decimal point.
  test "[component] a fractional entry fee still prints its cents" do
    @contest.update!(entry_fee_cents: 1950)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_match(/\$19\.50 entry/, money_line_for(@contest))
  end

  # --- hover -------------------------------------------------------------

  test "[component] a live contest card carries the hover lift" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)}[data-contest-hover=lift]", count: 1
    assert_select "#{card_for(@contest)}.tt-contest-card", count: 1
  end

  test "[component] a coming soon card does not answer the cursor" do
    @contest.update!(coming_soon: true)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{card_for(@contest)}[data-contest-hover]", count: 0
    assert_select "#{card_for(@contest)}.tt-contest-card", count: 0
    assert_select card_for(@contest), count: 1, message: "the card must still be on the rail"
  end

  # --- the card's width --------------------------------------------------

  # THE BANNER IS WHY THIS IS ASSERTED AT ALL. The banner is a 5:1 crop in a
  # fixed-height `object-cover` box, so the card's WIDTH is the only thing that
  # decides how much of the stored art survives the crop. The width is a class
  # and nothing but a class, so the class is what there is to pin; the rendered
  # measurement of the same rule rides in e2e/contests_rail.spec.js.
  #
  # The retired width is asserted absent as the falsifier: `w-80` alone still
  # matches on the class list this replaced, where it was the sm: step.
  test "[component] a rail card is wide enough to show more of its banner" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    wrapper = css_select(stack_for(@contest)).first
    assert wrapper, "the rail must hold a card wrapper"
    classes = wrapper["class"].split
    assert_includes classes, "w-80"
    assert_includes classes, "sm:w-96"
    assert_not_includes classes, "w-72", "the retired 288px width must not survive"
  end

  # --- the fizz ----------------------------------------------------------

  # The carbonation is the engine's (studio/_fizz_layer), and it is rendered
  # OUTSIDE the card on purpose: the card is `overflow-hidden`, so a layer
  # inside it would be clipped at exactly the edges the bubbles exist to cross.
  # Asserted as a PAIR — the layer is a direct child of the `.hold-stack`
  # wrapper, which is the engine selector that positions and z-orders it, and
  # NOT inside the card.
  test "[component] a live card's fizz sits outside the card, on the stack" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{stack_for(@contest)}.hold-stack.tt-contest-stack", count: 1,
      message: "the wrapper must be the engine's hold-stack or the layer has nothing to position against"
    assert_select "#{stack_for(@contest)} > .hold-fizz", count: 1
    assert_select "#{card_for(@contest)} .hold-fizz", count: 0,
      message: "a layer inside the overflow-hidden card would be clipped at the edges it must cross"
  end

  test "[component] the fizz layer carries bubbles to animate" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{stack_for(@contest)} > .hold-fizz .fizz-bit", minimum: 6
  end

  # Same line the hover lift draws: a contest that is not playable yet must not
  # be the liveliest thing on the page.
  # THE RAIL'S VERTICAL PADDING IS PART OF THE EFFECT, not spacing taste.
  # `overflow-x-auto` forces overflow-y to a non-visible value, so the rail box
  # clips whatever a card throws past its own top or bottom edge — and the
  # bubbles that cross those edges are the effect. The padding is the room they
  # cross INTO, and a bottom-only padding (what this replaced) leaves the top
  # half of the fizz clipped away with nothing on screen to say so.
  #
  # WHAT THIS DOES AND DOES NOT PROVE: it pins the declaration, not the pixels.
  # Only a browser can measure a bubble against the clip box, and that
  # measurement is not collected at this tier.
  test "[component] the rail keeps room above and below for the fizz to escape" do
    log_in_as(@alex)

    get contests_path

    assert_response :success
    rail = css_select("[data-contest-rail]").first
    assert rail, "the rail must render"
    classes = rail["class"].split
    assert_includes classes, "py-5"
    assert_empty classes.grep(/\Apb-/),
      "a bottom-only padding clips the top half of every card's fizz"
  end

  test "[component] a coming soon card gets no fizz at all" do
    @contest.update!(coming_soon: true)
    log_in_as(@alex)

    get contests_path

    assert_response :success
    assert_select "#{stack_for(@contest)} .hold-fizz", count: 0
    assert_select "#{stack_for(@contest)} .fizz-bit", count: 0
    assert_select stack_for(@contest), count: 1, message: "the card must still be on the rail"
  end
end
