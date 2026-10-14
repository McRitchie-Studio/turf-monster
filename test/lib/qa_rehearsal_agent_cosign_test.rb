# frozen_string_literal: true

require "test_helper"

# Step 4's two exits. `--cosign agent` (the default since 2026-10-12) settles
# unattended on devnet v0.26 with the server key plus a seated devnet-only agent
# key, and confirms on the dyno; `--cosign link` mints a Phantom link. Neither
# signs in as an admin over HTTP: no agent-readable wallet is an admin.
class QaRehearsalAgentCosignTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  # A driver whose first outside reach fails the test by name.
  def driver
    Driver.new(io: StringIO.new).tap do |d|
      d.define_singleton_method(:guard!) { raise "reached the network guard" }
    end
  end

  test "both co-sign modes reach the network guard first" do
    %i[agent link].each do |mode|
      error = assert_raises(RuntimeError) { driver.conclude(cosign: mode) }
      assert_equal "reached the network guard", error.message
    end
  end

  test "an unknown co-sign mode is refused before the guard" do
    error = assert_raises(Driver::StepError) { driver.conclude(cosign: :phantom) }
    assert_match(/agent or link/, error.message)
  end

  test "conclude and the CLI default to the unattended agent co-sign" do
    error = assert_raises(RuntimeError) { driver.conclude }

    assert_equal "reached the network guard", error.message
    # The CLI's default now lives in Options; read it parsed, not as source text.
    assert_equal :agent, TurfMonster::QaRehearsal::Options.parse(%w[conclude]).last[:cosign]
  end

  test "on a v0.25 dyno the agent co-sign refuses before it grades or locks anything" do
    d = Driver.new(io: StringIO.new)
    d.define_singleton_method(:guard!) { true }
    d.instance_variable_set(:@manifest, Struct.new(:x) { def read = { "contest_slug" => "c" } }.new(nil))
    calls = []
    remote = Object.new
    remote.define_singleton_method(:call) do |src|
      calls << src
      { "governance" => false }
    end
    d.instance_variable_set(:@remote, remote)

    error = assert_raises(Driver::StepError) { d.conclude(cosign: :agent) }

    assert_match(/needs turf-vault v0.26/, error.message)
    assert_equal 1, calls.size, "only the governance probe ran"
  end

  test "no admin actor is filed or driven" do
    refute TurfMonster::QaRehearsal::KeyStore::ITEMS.keys.any? { |k| k.include?("admin") }
    refute_includes Rails.root.join("lib/turf_monster/qa_rehearsal/driver.rb").read, "admin_session"
  end
end
