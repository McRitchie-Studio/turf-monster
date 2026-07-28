# frozen_string_literal: true

# The development-only demo contest — one standard "NFL 2026 Weeks 1-3" contest
# so a freshly-created worktree has something to play with. Loaded from
# db/seeds.rb behind a `Rails.env.development?` gate; see the call site there.
#
# Why the canonical seed creates no contests (db/seeds.rb, "Create Slates"):
# contest data — entries, payouts, multisig settlement — is the production
# surface we want to exercise deliberately, and a scaffolded contest confuses a
# friend-test participant about what is real. That reasoning covers QA and
# production. A fresh dev worktree has the opposite problem: `bin/rails
# db:prepare` seeds slates but no contest, so /contests renders "No contests
# yet." and the whole pick-and-enter surface is unreachable.
#
# Two properties keep this demo clear of real contests:
#
#   * DEVELOPMENT ONLY — the gate lives at the call site, so QA and production
#     seed exactly as they did before.
#   * OFF-CHAIN — `skip_onchain_callback`, so seeding never needs a funded
#     devnet wallet and the demo can never collide with a real on-chain Contest
#     PDA created through /contests/generator. e2e/seed.rb builds its fixture
#     contests the same way.
#
# Played on the ONE span slate Nfl::BuildSpanSlate builds, which is what freezes
# each team's turf_score across the three weeks — the demo therefore exercises
# real multi-week pricing rather than a hand-built stand-in.

DEMO_CONTEST_SLUG = "nfl-2026-weeks-1-3"
DEMO_CONTEST_YEAR = 2026
DEMO_CONTEST_WEEKS = [1, 2, 3].freeze

# Returns the demo Contest. Idempotent: an existing one is returned UNTOUCHED,
# so re-seeding never re-prices it, re-opens a settled one, or disturbs the
# entries you were playing with locally.
def seed_nfl_demo_contest!
  existing = Contest.find_by(slug: DEMO_CONTEST_SLUG)
  if existing
    puts "  Demo contest already present: #{existing.name} (/contests/#{existing.slug})"
    return existing
  end

  slate = Nfl::BuildSpanSlate.call(year: DEMO_CONTEST_YEAR, weeks: DEMO_CONTEST_WEEKS)
  format = Contest::FORMATS.fetch("standard")

  contest = Contest.new(
    name: slate.name,
    slug: DEMO_CONTEST_SLUG,
    slate: slate,
    contest_type: "standard",
    entry_fee_cents: format.fetch(:entry_fee_cents),
    max_entries: format.fetch(:max_entries),
    status: "open",
    starts_at: slate.first_game_starts_at || slate.starts_at
  )
  contest.skip_onchain_callback = true
  contest.save!

  puts "  Created demo contest: #{contest.name} " \
       "(/contests/#{contest.slug}, #{slate.slate_matchups.count} matchups)"
  contest
end
