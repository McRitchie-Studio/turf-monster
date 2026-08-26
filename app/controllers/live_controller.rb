# The league-wide live scoreboard at /live.
#
# Public and read-only: no contest, no entry, no sign-in. It is the visual
# medium for the NFL score feed — what the poller writes, this renders, and the
# websocket keeps it honest between page loads.
class LiveController < ApplicationController
  # Public, like the trust pages in PagesController. A scoreboard that demands
  # a sign-in to show a score is not a scoreboard.
  skip_before_action :require_authentication

  def index
    @slot = Nfl::LiveScores::CurrentSlot.call
    @games = Nfl::LiveScores::CurrentSlot.games_for(@slot)
  end
end
