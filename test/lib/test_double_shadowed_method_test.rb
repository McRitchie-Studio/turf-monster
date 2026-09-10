require "test_helper"

# [unit] NO TEST DOUBLE MAY DEFINE THE SAME METHOD TWICE.
#
# Ruby does not warn when a class body defines one method twice. It keeps the
# LAST one and drops the first without a sound — no error, no deprecation, and a
# green suite either way. In application code a second definition is usually
# caught by review because the bodies sit near each other; in a 700-line test
# double they can be 230 lines apart, and the reader who scrolls to the FIRST one
# builds a mental model of the double that is simply wrong.
#
# THE DEFECT THIS WAS WRITTEN FOR (found 2026-09-07, /tasks/sweep-get-usdc-claims,
# pre-existing). test/support/fake_vault.rb defined `entry_pda` at :151 and again
# at :380. Ruby kept :380. The dead :151 carried a comment teaching a return value
# — `["epda-derived", 255]` — that no caller has ever received, in the double that
# stands in for the chain across every entry suite.
#
# AND DELETING IT PROVED NOTHING BY ITSELF, which is the reason this guard exists
# rather than a note in a commit message. Removing dead code leaves the suite
# exactly as green as it was, so "the tests still pass" is not evidence the right
# copy survived. Four things were: `source_location` named :380; the returned
# value matched :380's body; an unconditional `raise` in :151's body left 196 runs
# / 797 assertions green across the entry suites; and the same raise in :380 broke
# them loudly. This guard makes the next occurrence fail at the seam instead,
# where no one has to think of running that experiment.
#
# SCOPE: test/support/*.rb, the shared doubles. Deliberately NOT all of test/.
# Two idioms elsewhere in this tree define a name twice ON PURPOSE and are not
# bugs — `def client.get_account_info` on two different local stub objects
# (test/controllers/admin/currencies_controller_test.rb), and a `def geo_state`
# redefined inside each `test` block before it is called
# (test/helpers/birthday_modal_helper_test.rb). A guard that cried about those
# would be turned off, so it looks only where a repeat is unambiguously a bug:
# plain instance methods in the body of a plain double class.
class TestDoubleShadowedMethodTest < ActiveSupport::TestCase
  SUPPORT_GLOB = Rails.root.join("test", "support", "*.rb").to_s

  # Instance methods (DEFN) declared directly in a class/module BODY, keyed by
  # "Scope#name" => [line, ...].
  #
  # Two deliberate blind spots, both to keep the guard from flagging a legitimate
  # idiom: singleton definitions (`def obj.meth`, DEFS) are skipped, because two
  # of them usually belong to two different objects; and the walk does not
  # descend into blocks (ITER), because a `def` inside a `test do ... end` block
  # re-defines the method every run on purpose.
  def definitions_in(path)
    tree = RubyVM::AbstractSyntaxTree.parse_file(path)
    found = Hash.new { |h, k| h[k] = [] }
    walk(tree, [], found)
    found
  end

  def walk(node, scope, found)
    return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    case node.type
    when :CLASS, :MODULE
      const = node.children[0]
      name  = const.respond_to?(:children) ? const.children.compact.last.to_s : const.to_s
      node.children.each { |child| walk(child, scope + [name], found) }
    when :DEFN
      found["#{scope.join('::')}##{node.children[0]}"] << node.first_lineno
    when :DEFS, :ITER
      # See the blind spots above. Not descended into on purpose.
      nil
    else
      node.children.each { |child| walk(child, scope, found) }
    end
  end

  test "the shared test doubles define each method exactly once" do
    files = Dir[SUPPORT_GLOB].sort

    # A GLOB THAT MATCHES NOTHING WOULD PASS THIS TEST SILENTLY. Assert the input
    # reached the guard before reading its verdict — a rename of test/support/
    # must fail here, not go quiet.
    assert_operator files.length, :>=, 5,
                    "expected the shared doubles under test/support/; found #{files.length} " \
                    "file(s) at #{SUPPORT_GLOB} — has the directory moved?"

    shadowed = files.flat_map do |path|
      definitions_in(path).filter_map do |qualified, lines|
        next if lines.length < 2

        "#{path.delete_prefix(Rails.root.to_s + '/')}: #{qualified} defined " \
          "#{lines.length} times (lines #{lines.join(', ')})"
      end
    end

    assert_empty shadowed,
                 "Ruby keeps only the LAST definition and drops the earlier ones in silence, " \
                 "so the dead copy's body and its comment describe behaviour no caller ever " \
                 "sees. Delete the copy nothing reaches — and prove which one is live before " \
                 "you pick (Object#method(:name).source_location, or a temporary raise in the " \
                 "body you believe is dead), because deleting the dead one changes nothing " \
                 "and a green suite alone cannot tell you that you chose right.\n  " +
                 shadowed.join("\n  ")
  end
end
