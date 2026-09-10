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
    # WHICH game the board opens on. Only the OPENING one: after first paint
    # the choice belongs to the reader, held in Alpine state on the page
    # wrapper where no broadcast can reach it (see live/index).
    @focus_slug = Live::FocusGame.call(@games)
  end
end
