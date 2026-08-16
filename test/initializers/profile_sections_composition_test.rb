require "test_helper"

# [unit] What this app declares for the shared /profile page.
#
# The lambda ignores the view — it composes against
# Studio.default_profile_sections — so calling it directly is the honest test of
# the DECLARATION, separate from whether any of it renders.
#
# Two properties, and both have already been got wrong once:
#
#   COMPOSED, NOT LISTED. A literal array here would silently drop whatever row
#   the engine adds next. Composing means a new engine row arrives automatically.
#
#   REPLACED BY KEY, NOT REJECTED-AND-APPENDED. Rejecting the engine's newsletter
#   row and pushing ours on the end puts it AFTER birthday instead of where the
#   engine had it, which reorders the page for no reason anyone asked for.
class ProfileSectionsCompositionTest < ActiveSupport::TestCase
  def declared = Studio.profile_sections.call(nil)

  test "the engine's rows arrive in the engine's order, plus this app's own" do
    engine_keys = Studio.default_profile_sections.map { |s| s[:key].to_sym }

    assert_equal engine_keys + [:quests], declared.map { |s| s[:key].to_sym },
                 "a literal list here would drop the next row the engine adds; " \
                 "appending our newsletter row instead of replacing it would reorder the page"
  end

  # THE ROW THIS APP TAKES OVER. The engine's newsletter row is a plain form and a
  # confirm dialog — right for an app with no rewards, wrong for this one, where
  # joining is worth 25 seeds and leaving costs them.
  test "the newsletter row is this app's partial, not the engine's" do
    row = declared.find { |s| s[:key].to_sym == :newsletter }

    refute_nil row
    assert_equal "accounts/newsletter_section", row[:partial]
    assert_equal :show, row[:page], "it is a thing you look at, not a field you type into"
  end

  # Quests are unique to this app by the operator's call — the engine has no
  # concept of them, so this row names a host partial.
  test "the quests row names this app's own partial" do
    row = declared.find { |s| s[:key].to_sym == :quests }

    refute_nil row
    assert_equal "accounts/quests", row[:partial]
  end

  # The seam that lets the engine's own route still pay the bonus. Nothing in the
  # UI calls it today (the modals post to this app's controller), but the route is
  # public and a subscribe arriving there without this would burn
  # first_newsletter_join? forever.
  test "the newsletter callback is wired as a safety net" do
    assert Studio.after_newsletter_change.respond_to?(:call)
    assert_equal %i[user], Studio.after_newsletter_change.parameters.select { |t, _| t == :req }.map(&:last)
  end
end
