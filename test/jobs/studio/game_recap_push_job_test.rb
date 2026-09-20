require "test_helper"

# [unit] The job's two guards. Both exist so a retry long after the fact cannot
# raise: a game may have been deleted, and the secret may never have been set.
class Studio::GameRecapPushJobTest < ActiveSupport::TestCase
  setup { @game = games(:past_game) }

  test "does nothing for a game that no longer exists" do
    ENV["AGENT_API_SECRET"] = "shh"
    called = false
    Studio::PushGameRecap.stub(:new, ->(*) { called = true }) do
      Studio::GameRecapPushJob.perform_now("no-such-game")
    end

    assert_not called
  ensure
    ENV.delete("AGENT_API_SECRET")
  end

  test "does nothing when no secret is configured" do
    ENV.delete("AGENT_API_SECRET")
    called = false
    Studio::PushGameRecap.stub(:new, ->(*) { called = true }) do
      Studio::GameRecapPushJob.perform_now(@game.slug)
    end

    assert_not called
  end

  test "pushes the game when configured" do
    ENV["AGENT_API_SECRET"] = "shh"
    pushed = nil
    fake = Object.new
    fake.define_singleton_method(:call) { true }

    Studio::PushGameRecap.stub(:new, ->(game) { pushed = game; fake }) do
      Studio::GameRecapPushJob.perform_now(@game.slug)
    end

    assert_equal @game.slug, pushed.slug
  ensure
    ENV.delete("AGENT_API_SECRET")
  end
end
