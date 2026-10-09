# frozen_string_literal: true

require "test_helper"

# The agent co-sign ends by confirming the settle over the admin HTTP surface,
# signed in by wallet. The rehearsal files no admin actor, so that path refuses
# before it locks, grades or broadcasts anything.
class QaRehearsalAgentCosignTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver
  CLI = Rails.root.join("bin/qa-contest-rehearsal").read.freeze

  # A driver whose first outside reach fails the test by name.
  def driver
    Driver.new(io: StringIO.new).tap do |d|
      d.define_singleton_method(:guard!) { raise "reached the network guard" }
    end
  end

  test "the agent co-sign refuses before the step touches anything" do
    error = assert_raises(Driver::StepError) { driver.conclude(cosign: :agent) }

    assert_match(/conclude --cosign link/, error.message)
  end

  test "the attended co-sign is not refused" do
    error = assert_raises(RuntimeError) { driver.conclude(cosign: :link) }

    assert_equal "reached the network guard", error.message
  end

  test "conclude and the CLI default to the attended co-sign" do
    error = assert_raises(RuntimeError) { driver.conclude }

    assert_equal "reached the network guard", error.message
    assert_includes CLI, "cosign: :link,"
    refute_includes CLI, "cosign: :agent"
  end

  test "the admin actor has no filed key" do
    refute TurfMonster::QaRehearsal::KeyStore::ITEMS.key?(Driver::ADMIN_ACTOR)
  end
end
