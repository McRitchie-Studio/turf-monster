# The web's own view rules, answered for an API caller.
#
# ContestsHelper holds two rules the API must not restate: who may see an
# entry's picks (#picks_visible_for?) and how much room a field has left
# (#contest_spots_left). Both are written against a view context, so this object
# IS a minimal one: it includes the helper and supplies the two things the rules
# ask of a view, the viewer and whether there is one. The rule that runs is the
# helper's, byte for byte.
#
# `@admin_view` is never set here, so the helper's admin bypass (the
# /contests/:slug/admin page) stays off: an admin's API key sees rival picks on
# the same terms as any other player.
module Api
  module V1
    class WebRules
      include ContestsHelper

      def initialize(viewer)
        @viewer = viewer
      end

      def picks_visible?(entry, contest)
        picks_visible_for?(entry, lock_memo(contest))
      end

      def spots_left(contest, entries_count)
        contest_spots_left(contest, entries_count)
      end

      private

      # The helper asks `contest.locked?` once per entry, and for a contest with
      # no starts_at that is a query for the slate's first kickoff each time: a
      # leaderboard page paid one per row. The answer cannot change within a
      # request, so the contest is handed to the helper behind a wrapper that
      # asks once. The rule that runs is still the helper's.
      class LockMemo < SimpleDelegator
        def locked?
          @locked = __getobj__.locked? unless defined?(@locked)
          @locked
        end
      end

      def lock_memo(contest)
        (@lock_memos ||= {})[contest.id] ||= LockMemo.new(contest)
      end

      def current_user
        @viewer
      end

      def logged_in?
        @viewer.present?
      end
    end
  end
end
