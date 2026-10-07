require "test_helper"

# [unit] PageExperiment and PageVariant: the weighted draw (deterministic under
# a seeded RNG), the assignment precedence (?v= > bot > sticky cookie > draw),
# what is stored and counted, and the rules that keep an experiment splittable.
class PageExperimentTest < ActiveSupport::TestCase
  include PageExperimentFixture

  setup { @experiment = create_page_experiment }

  # --- the draw ------------------------------------------------------------------

  test "the draw is deterministic under a seeded RNG" do
    first = Array.new(20) { @experiment.sample(rng: Random.new(7)).key }
    second = Array.new(20) { @experiment.sample(rng: Random.new(7)).key }
    assert_equal first, second

    rng_a = Random.new(42)
    rng_b = Random.new(42)
    assert_equal Array.new(50) { @experiment.sample(rng: rng_a).key },
                 Array.new(50) { @experiment.sample(rng: rng_b).key }
  end

  test "50/50 weights split close to even, and 3:1 close to three to one" do
    rng = Random.new(1234)
    counts = Array.new(4000) { @experiment.sample(rng: rng).key }.tally
    assert_in_delta 2000, counts["control"], 120
    assert_in_delta 2000, counts["fantasy-football"], 120

    skewed = create_page_experiment(slug: "skewed", page_path: "/elsewhere", weights: { "control" => 3, "fantasy-football" => 1 })
    counts = Array.new(4000) { skewed.sample(rng: rng).key }.tally
    assert_in_delta 3000, counts["control"], 120
  end

  test "a variant at weight 0 is never drawn" do
    @experiment.variants.find_by!(key: "fantasy-football").update!(weight: 0)
    @experiment.reload
    rng = Random.new(3)
    assert_equal ["control"], Array.new(200) { @experiment.sample(rng: rng).key }.uniq
  end

  test "the draw walks the weights: a fixed pick lands on the arm whose band holds it" do
    fixed = Struct.new(:value) { def rand(_max) = value }
    assert_equal "control", @experiment.sample(rng: fixed.new(0)).key
    assert_equal "fantasy-football", @experiment.sample(rng: fixed.new(1)).key
  end

  # --- assignment -------------------------------------------------------------------

  test "a new visitor is drawn, and the draw is to be stored and counted" do
    a = @experiment.assign(rng: Random.new(1))
    assert_equal :sampled, a.source
    assert a.store?
    assert a.counted?
  end

  test "a visitor's cookie is sticky: the same variant, nothing new to store" do
    10.times do |seed|
      a = @experiment.assign(cookie: "fantasy-football", rng: Random.new(seed))
      assert_equal "fantasy-football", a.key
      assert_equal :cookie, a.source
      refute a.store?
      assert a.counted?
    end
  end

  test "an explicit ?v= wins over the cookie, and re-pins the visitor" do
    a = @experiment.assign(param: "control", cookie: "fantasy-football")
    assert_equal "control", a.key
    assert_equal :param, a.source
    assert a.store?
  end

  test "?v= is read case-insensitively; an unknown one is ignored" do
    assert_equal "fantasy-football", @experiment.assign(param: " Fantasy-Football ").key
    a = @experiment.assign(param: "nope", cookie: "fantasy-football")
    assert_equal :cookie, a.source
  end

  test "a cookie naming a variant that no longer exists is redrawn" do
    a = @experiment.assign(cookie: "retired", rng: Random.new(1))
    assert_equal :sampled, a.source
  end

  test "a bot gets the control, is never stored and never counted, whatever its cookie" do
    a = @experiment.assign(cookie: "fantasy-football", bot: true)
    assert_equal "control", a.key
    refute a.store?
    refute a.counted?
  end

  test "a bot's explicit ?v= still renders that variant (an unfurl of a shared link) but is not stored or counted" do
    a = @experiment.assign(param: "fantasy-football", bot: true)
    assert_equal "fantasy-football", a.key
    refute a.store?
    refute a.counted?
  end

  test "the control is the variant keyed control, else the first in order" do
    assert_equal "control", @experiment.control_variant.key
    other = PageExperiment.create!(slug: "no-control", name: "x", page_path: "/x",
                                   variants_attributes: [{ key: "b", position: 1 }, { key: "a", position: 0 }])
    assert_equal "a", other.control_variant.key
  end

  # --- lookup and rules ---------------------------------------------------------------

  test ".for_page finds only a running experiment" do
    assert_equal @experiment, PageExperiment.for_page("/turf-monster-v2")
    @experiment.update!(active: false)
    assert_nil PageExperiment.for_page("/turf-monster-v2")
  end

  test "one running experiment per page" do
    second = PageExperiment.new(slug: "second", name: "x", page_path: "/turf-monster-v2",
                                variants_attributes: [{ key: "a" }, { key: "b" }])
    refute second.valid?
    assert_match(/already running/, second.errors[:active].join)
    second.active = false
    assert second.valid?, "a paused one can wait on the same page"
  end

  test "an experiment needs two variants with distinct keys and some weight" do
    e = PageExperiment.new(slug: "one", name: "x", page_path: "/p", variants_attributes: [{ key: "a" }])
    refute e.valid?
    assert_match(/at least two/, e.errors[:variants].join)

    e = PageExperiment.new(slug: "dup", name: "x", page_path: "/p", variants_attributes: [{ key: "a" }, { key: "A" }])
    refute e.valid?
    assert_match(/different key/, e.errors[:variants].join)

    e = PageExperiment.new(slug: "zero", name: "x", page_path: "/p",
                           variants_attributes: [{ key: "a", weight: 0 }, { key: "b", weight: 0 }])
    refute e.valid?
    assert_match(/weight above 0/, e.errors[:variants].join)
  end

  test "the page must be a local path with no query" do
    %w[https://evil.example/x //evil.example /p?x=1 turf].each do |path|
      e = PageExperiment.new(slug: "p", name: "x", page_path: path, variants_attributes: [{ key: "a" }, { key: "b" }])
      refute e.valid?, "#{path} must be refused"
    end
  end

  test "the slug cannot change after create: it keys the cookie and every count" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @experiment.update!(slug: "renamed") }
    assert_equal "turf-monster-v2", @experiment.reload.slug
    assert_equal "exp_turf-monster-v2", @experiment.cookie_name
  end

  test "a variant's headline splits into lines, blanks dropped; four lines at most" do
    v = @experiment.variants.find_by!(key: "fantasy-football")
    assert_equal ["NFL Team", "Fantasy", "Football"], v.headline_lines
    v.headline = "a\n\nb\n c "
    assert_equal %w[a b c], v.headline_lines
    v.headline = "1\n2\n3\n4\n5"
    refute v.valid?
  end

  test "a variant key is a short lowercase slug" do
    v = @experiment.variants.build(key: "Has Space")
    refute v.valid?
    v.key = "  New-Arm "
    v.valid?
    assert_equal "new-arm", v.key
  end
end
