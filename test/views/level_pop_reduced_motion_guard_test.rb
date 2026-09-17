require "test_helper"

# Component tier for the level-up pops under reduced motion
# (task: level-pop-ignores-reduced-motion).
#
# THE BUG. studio-engine's engine-motion.css defines .level-up-pop and
# .nav-level-pop and stops both under `prefers-reduced-motion: reduce`. That
# import compiles into `@layer components`. application.css then defined both
# classes again: .level-up-pop unlayered and .nav-level-pop as an @utility. An
# unlayered rule beats every layered one, and a utility beats a component, so
# either copy outranked the engine's reduced-motion rule. MEASURED in headless
# Chromium with reduced motion forced: both classes still ran their animations.
#
# THE FIX deletes the app copies, so the engine's pair (animation rule, then the
# reduced-motion rule in the same layer) is the only thing the cascade sees.
#
# WHAT THIS GUARDS. For each pop class, every compiled rule that sets an
# animation must be outranked by a reduced-motion `animation: none` for the
# same class: same layer, later in the file. Order only decides within one
# layer, so a copy in any other layer (or none) fails, whichever way it wins.
class LevelPopReducedMotionGuardTest < ActiveSupport::TestCase
  POP_CLASSES = %w[level-up-pop nav-level-pop].freeze

  # Walks the stylesheet once, recording each rule with its selector list, its
  # declarations, and the chain of at-rules it sits in.
  Rule = Struct.new(:selectors, :body, :context, :offset)

  def self.rules(css)
    css = css.gsub(%r{/\*.*?\*/}m, "")
    rules = []
    stack = []
    cursor = 0
    css.scan(/[{};]/) do
      match = Regexp.last_match
      prelude = css[cursor...match.begin(0)].strip
      case match[0]
      when "{"
        stack << [prelude, match.end(0)]
      when "}"
        opened = stack.pop
        if opened && !opened[0].start_with?("@")
          body = css[opened[1]...match.begin(0)]
          rules << Rule.new(opened[0].split(",").map(&:strip), body, stack.map(&:first), opened[1])
        end
      end
      cursor = match.end(0)
    end
    rules
  end

  # The layer names a rule sits in ("" when unlayered), ignoring @media and the like.
  def self.layers(context) = context.grep(/\A@layer\b/).join(" > ")

  def self.reduced_motion?(context) = context.any? { |c| c.match?(/prefers-reduced-motion\s*:\s*reduce/) }

  # Returns one message per animating rule that no reduced-motion rule outranks.
  def self.unguarded(css, klass)
    selector = ".#{klass}"
    all = rules(css).select { |r| r.selectors.include?(selector) }
    stops = all.select { |r| reduced_motion?(r.context) && r.body.match?(/animation\s*:\s*none/) }
    moving = all.reject { |r| reduced_motion?(r.context) }.select { |r| r.body.match?(/animation(-name)?\s*:\s*(?!none)/) }

    moving.filter_map do |rule|
      next if stops.any? { |stop| layers(stop.context) == layers(rule.context) && stop.offset > rule.offset }
      "#{selector} at offset #{rule.offset} in layer [#{layers(rule.context).presence || 'unlayered'}]: #{rule.body.strip[0, 90]}"
    end
  end

  ENGINE_SHAPE = <<~CSS.freeze
    @layer components{.level-up-pop{z-index:10;animation:1.1s levelPop,1.4s ease-out levelGlow}.nav-level-pop{animation:.8s navLevelPop}
    @media (prefers-reduced-motion:reduce){.level-badge-9,.level-up-pop,.nav-level-pop{animation:none}}}
  CSS

  test "the detector passes the engine shape and bites both app copies" do
    POP_CLASSES.each { |klass| assert_empty self.class.unguarded(ENGINE_SHAPE, klass), "false positive on #{klass}" }

    # The shipped defect, as Tailwind compiled it: an unlayered .level-up-pop and
    # an @utility .nav-level-pop, both after the engine's layer.
    shipped = ENGINE_SHAPE + "@layer utilities{.email-reject{animation:.55s email-reject}.nav-level-pop{animation:.8s navLevelPop}}" \
                             ".level-up-pop{z-index:10;animation:1.1s levelPop,1.4s ease-out levelGlow}"
    POP_CLASSES.each { |klass| assert_equal 1, self.class.unguarded(shipped, klass).size, "detector missed the #{klass} copy" }

    # Same layer but BEFORE the stop is fine; same layer AFTER it is not.
    after_stop = ENGINE_SHAPE.sub(/\}\n?\z/, ".nav-level-pop{animation:.8s navLevelPop}}")
    assert_equal 1, self.class.unguarded(after_stop, "nav-level-pop").size, "detector missed a later same-layer copy"
  end

  test "reduced motion outranks every compiled animation on both pop classes" do
    css = CssClassGuard.stylesheet
    POP_CLASSES.each do |klass|
      assert self.class.rules(css).any? { |r| r.selectors.include?(".#{klass}") && self.class.reduced_motion?(r.context) },
        "no reduced-motion rule for .#{klass} in the compiled stylesheet; the engine's motion layer is not reaching it"
    end

    offenders = POP_CLASSES.flat_map { |klass| self.class.unguarded(css, klass) }
    assert_empty offenders, <<~MSG
      A compiled rule animates a level-up pop that no prefers-reduced-motion rule
      outranks, so the pop runs with reduced motion on. The motion lives in
      studio-engine's engine-motion.css (@layer components); delete the app copy:
      #{offenders.join("\n")}
    MSG
  end

  test "the level-up keyframes are defined once" do
    css = CssClassGuard.stylesheet
    %w[levelPop levelGlow navLevelPop].each do |name|
      assert_equal 1, css.scan(/@keyframes\s+#{name}\s*\{/).size,
        "@keyframes #{name} is defined more than once (or not at all). An unlayered copy beats the engine's layered one."
    end
  end
end
