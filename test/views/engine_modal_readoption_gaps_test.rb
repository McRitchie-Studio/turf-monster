require "test_helper"

# [component] Why turf still carries nine modal partials the engine looks like it
# could render, and the tripwire that says when that stops being true.
#
# turf-readopts-engine-modals (2026-10-24, studio-engine 0.113.0.rc1) compared
# each candidate against the engine block named for it and kept all nine: none
# matched in both pixels and behaviour. Each kept file opens with an ENGINE
# STATUS header saying exactly what the engine lacks.
#
# THE GAP TESTS READ THE ENGINE, NOT THIS APP. Each asserts that the engine block
# still lacks the thing the header names. When an engine release closes a gap,
# that test goes red on the bump: that is the signal to readopt the engine block
# and delete the turf copy, not to loosen the assertion.
class EngineModalReadoptionGapsTest < ActiveSupport::TestCase
  MODALS = Rails.root.join("app/views/modals")
  ENGINE_VIEWS = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir).join("app/views/studio")

  KEPT = %w[
    newsletter_email newsletter_subscribe newsletter_success
    unsubscribe_confirm unsubscribe_goodbye
    username birthday rate_limit_general email_change_pending
  ].freeze

  def engine(path)
    ENGINE_VIEWS.join(path).read
  end

  test "every kept modal names, in its header, why it is kept and what the engine owes" do
    KEPT.each do |name|
      src = MODALS.join("_#{name}.html.erb").read
      header = src[/\A<%#(.*?)%>/m, 1].to_s
      assert_includes header, "ENGINE STATUS", "_#{name}: the first comment must be the ENGINE STATUS header"
      assert_includes header, "KEPT", "_#{name}: the header must say the card is kept"
      assert_includes header, "Engine follow-up", "_#{name}: the header must name the engine follow-up"
    end
  end

  test "newsletter: the engine modals still answer to a different store and post a form" do
    src = engine("profiles/_newsletter_modals.html.erb")
    assert_includes src, "$store.profileModals",
      "the engine newsletter modals moved onto the app host's store: re-measure the five newsletter cards for readoption"
    assert_match(/form_with url: profile_newsletter_path/, src,
      "the engine newsletter modals stopped posting a plain form: re-measure the five newsletter cards for readoption")
    %w[newsletter-success unsubscribe-goodbye newsletter-subscribe].each do |id|
      assert_not_includes src, "'#{id}'",
        "the engine now registers #{id}: readopt it and delete turf's copy"
    end
  end

  test "birthday: the engine block still has no slot for the chain's progress pill" do
    src = engine("modals/blocks/_birthday.html.erb")
    assert_not_includes src, "progress_pill",
      "blocks/_birthday renders a progress pill now: render it from the layout and delete modals/_birthday"
    assert_no_match(/\byield\b/, src.gsub(/<%#.*?%>/m, ""),
      "blocks/_birthday takes a block now: pass the pill in and delete modals/_birthday")
  end

  test "rate limit: the engine error card still has no countdown and no store close" do
    src = engine("modals/blocks/_error_card.html.erb")
    assert_not_includes src, "setInterval",
      "blocks/_error_card counts down now: re-measure modals/_rate_limit_general for readoption"
    assert_no_match(/\$store\.\w+\.close\(\)|\.close\(\)/, src,
      "blocks/_error_card can close the modal store now: re-measure modals/_rate_limit_general for readoption")
  end

  test "email change pending: the engine success card still cannot close the modal store" do
    src = engine("modals/blocks/_success_card.html.erb")
    assert_no_match(/\.close\(\)/, src,
      "blocks/_success_card can close the modal store now: re-measure modals/_email_change_pending for readoption")
  end
end
