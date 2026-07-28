# frozen_string_literal: true

# The development-only demo contest — one standard three-week NFL contest so a
# freshly-created worktree has something to play with. Loaded from db/seeds.rb
# behind a `Rails.env.development?` gate; see the call site there.
#
# Why the canonical seed creates no contests (db/seeds.rb, "Create Slates"):
# contest data — entries, payouts, multisig settlement — is the production
# surface we want to exercise deliberately, and a scaffolded contest confuses a
# friend-test participant about what is real. That reasoning covers QA and
# production. A fresh dev worktree has the opposite problem: `bin/rails
# db:prepare` seeds slates but no contest, so /contests reads "No contests yet."
# and the whole pick-and-enter surface is unreachable.
#
# Three properties keep this demo clear of real contests:
#
#   * DEVELOPMENT ONLY — the gate lives at the call site, so QA and production
#     seed exactly as they did before.
#   * OFF-CHAIN — `skip_onchain_callback`, so seeding never needs a funded
#     devnet wallet and the demo can never collide with a real on-chain Contest
#     PDA created through /contests/generator. e2e/seed.rb builds its fixture
#     contests the same way. Consequence to know: paid entry is refused for an
#     off-chain contest (ContestsController#enter), so the demo is browsable and
#     pickable, and completing an entry still needs a real on-chain contest.
#   * ROLLING SPAN — the span is the first three weeks whose games are still
#     AHEAD, not a hardcoded Weeks 1-3. A worktree created in November needs a
#     pickable board, and a contest whose first kickoff has passed seeds locked.
#
# Played on the ONE span slate Nfl::BuildSpanSlate builds, which is what freezes
# each team's turf_score across the three weeks — the demo therefore exercises
# real multi-week pricing rather than a hand-built stand-in.

DEMO_CONTEST_YEAR = 2026
DEMO_CONTEST_SPAN_WEEKS = 3

# Returns the demo Contest. Idempotent for a given span: an existing one is
# returned UNTOUCHED, so re-seeding never re-prices it, re-opens a settled one,
# or disturbs the entries you were playing with locally. Re-seeding LATER in the
# season adds that span's contest alongside the old one rather than rewriting
# history — the earlier contest has already locked.
def seed_nfl_demo_contest!
  weeks = upcoming_demo_contest_weeks(DEMO_CONTEST_YEAR)
  slug = "nfl-#{DEMO_CONTEST_YEAR}-weeks-#{weeks.first}-#{weeks.last}"

  existing = Contest.find_by(slug: slug)
  if existing
    puts "  Demo contest already present: #{existing.name} (/contests/#{existing.slug})"
    return existing
  end

  slate = Nfl::BuildSpanSlate.call(year: DEMO_CONTEST_YEAR, weeks: weeks)
  format = Contest::FORMATS.fetch("standard")

  contest = Contest.new(
    name: slate.name,
    slug: slug,
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

# The DEMO_CONTEST_SPAN_WEEKS consecutive weeks the demo is played on: the first
# week whose games are still ahead, plus the two after it.
#
# Two edges worth stating:
#   * Near the end of the schedule the span SLIDES BACK to stay inside the weeks
#     that exist (Nfl::BuildSpanSlate refuses a gap rather than truncating), so
#     the last demo of a season can include weeks that already kicked off — and
#     that contest seeds locked. That is the floor the checked-in schedule sets,
#     not a choice.
#   * Once every week has kicked off it falls back to the first weeks, which is
#     the same locked-board case. Refreshing the schedule data is the fix.
def upcoming_demo_contest_weeks(year)
  weekly = Slate.where("name LIKE ?", "NFL #{year} %")
                .where.not(week: nil)
                .to_a
                .select { |slate| slate.week_range&.size == 1 }
                .sort_by(&:week)

  if weekly.size < DEMO_CONTEST_SPAN_WEEKS
    raise Nfl::BuildSpanSlate::Error,
          "NFL #{year} has #{weekly.size} weekly slate(s); a demo contest needs #{DEMO_CONTEST_SPAN_WEEKS}"
  end

  first_upcoming = weekly.find { |slate| (slate.first_game_starts_at || slate.starts_at)&.future? }
  start_week = first_upcoming&.week || weekly.first.week
  start_week = [start_week, weekly.last.week - DEMO_CONTEST_SPAN_WEEKS + 1].min

  (start_week...(start_week + DEMO_CONTEST_SPAN_WEEKS)).to_a
end
