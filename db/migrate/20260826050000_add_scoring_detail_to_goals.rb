# A `Goal` was born a soccer concept: one row = one goal = one point, and
# `Game#update_scores_from_goals!` scored a game by COUNTING rows. American
# football breaks that identity — a touchdown is worth six — so the NFL feed
# has no way to express itself in a count-based table. These three columns give
# a scoring event the shape it actually has.
#
# `points` — what this event is WORTH. Default 1 is the whole migration
# strategy: every existing World Cup goal row reads as exactly one point, so
# flipping `update_scores_from_goals!` from `count` to `sum(:points)` leaves
# every soccer score byte-identical while making TD=6 expressible. No backfill,
# no data rewrite, no behavior change for the sport already in production.
#
# `scoring_type` — WHICH kind of event it was (touchdown, field_goal,
# two_point, pat, safety, goal). Nullable because a soccer goal has no NFL
# scoring type and should not be forced to invent one. Read by the live toast
# so it can say "TOUCHDOWN" instead of the sport-neutral "GOAL".
#
# `external_id` — the upstream feed's OWN id for this scoring play (an ESPN
# play id such as "4018732851743"). This is the idempotency key, and it is the
# single reason a poller can run every 30 seconds for twelve hours without
# writing a touchdown twice. The unique index is what ENFORCES that: a re-poll
# of an unchanged game re-offers the same play ids and the database refuses
# them, so correctness does not depend on the poller's diffing being perfect.
#
# The index is partial (`WHERE external_id IS NOT NULL`) because hand-recorded
# goals — the admin console, the dev toolbar, the World Cup seed — legitimately
# have no upstream id. Without the predicate, the second NULL would collide.
class AddScoringDetailToGoals < ActiveRecord::Migration[8.0]
  def change
    add_column :goals, :points, :integer, default: 1, null: false
    add_column :goals, :scoring_type, :string
    add_column :goals, :external_id, :string

    add_index :goals, :external_id,
              unique: true,
              where: "external_id IS NOT NULL",
              name: "index_goals_on_external_id_when_present"
  end
end
