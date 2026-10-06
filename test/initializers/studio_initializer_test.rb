# frozen_string_literal: true

require "test_helper"

# config/initializers/studio.rb sets only settings studio-engine still reads.
#
# The engine retired Studio.magic_link_token_name and Studio.magic_link_store at
# 0.31.0: every magic link is a Studio::Link row, nothing reads the token name,
# and the store writer accepts :database alone. The engine keeps both accessors
# only so an initializer that still sets them boots; it drops them once no
# consumer sets them, and an initializer that still did would then fail to boot.
class StudioInitializerTest < ActiveSupport::TestCase
  INITIALIZER = Rails.root.join("config/initializers/studio.rb")
  RETIRED = %w[magic_link_token_name magic_link_store].freeze

  # [unit] Neither retired key appears in the initializer, as a setting or a comment.
  test "the initializer names no retired magic-link setting" do
    source = File.read(INITIALIZER)

    RETIRED.each do |key|
      refute source.match?(/\b#{key}\b/), "config/initializers/studio.rb still names #{key}"
    end
  end

  # [integration] The app boots in test with the engine loaded and this
  # initializer applied.
  test "the app boots with studio-engine loaded and configured" do
    assert_includes Rails.application.railties.map(&:class), Studio::Engine
    assert_equal "Turf Monster", Studio.app_name
  end
end
