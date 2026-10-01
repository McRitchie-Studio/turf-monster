# The caller's own entries: read them, create one, replace its picks
# (docs/AGENT_API.md). Each action names an operation
# (app/services/api/v1/operations), which the MCP endpoint calls too.
#
# WHICH ENTRIES. Confirmed ones: `active` (submitted, contest not graded) and
# `complete` (graded). That is Entry.confirmed, the same set the web counts
# toward leaderboards, the per-player limit and "contests I've entered".
#
# A `cart` entry is NOT served, and neither is an `abandoned` one. A cart is the
# website's half-built lineup, saved one tap at a time before the player pays.
# It has no score, no rank and no place on a leaderboard, and the API neither
# builds one nor touches the player's: an API entry is created whole, paid for
# in the same call, or not created at all (Entries::ApiSubmission).
#
# Another player's entry slug is a 404, the same answer as a slug that does not
# exist. Rivals are read through the contest leaderboard, under its own rule.
#
# THE WRITES. Both run behind the account hold (default-deny on every non-GET,
# ApiKeyAuthentication) and the age gate, asked again here because a key's
# stamp can predate the gate being switched on. Location is not re-asked: it
# was decided in the player's browser when the key was created.
module Api
  module V1
    class EntriesController < BaseController
      before_action :require_age_verified, only: %i[create update]

      def index
        run Operations::ListEntries
      end

      def show
        run Operations::GetEntry
      end

      # POST /api/v1/contests/:slug/entries. Created and funded in one call or
      # not at all; the Idempotency-Key is what makes a retry safe.
      def create
        run Operations::SubmitEntry, idempotency_key: request.headers["Idempotency-Key"]
      end

      # PATCH /api/v1/entries/:slug. Replaces the entry's picks.
      def update
        run Operations::EditEntry
      end
    end
  end
end
