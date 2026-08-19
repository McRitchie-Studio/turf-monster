# View seam for the onboarding card's animated placeholder.
module OnboardingHelper
  # First names of the 2026 starting quarterbacks, sampled at random so the
  # first-name card types a different one each time it opens.
  #
  # FIRST NAMES ONLY, and that is the whole point: the field asks for a first
  # name, so the example has to BE one. It also keeps the list from reading as a
  # roster — a player's presence here is a writing sample, not a claim about a
  # depth chart.
  #
  # WHY A HARD-CODED LIST. Turf has no NFL player data to draw on: the `players`
  # table holds World Cup soccer players (Messi, Vinícius…), and the NFL side of
  # the app is team-totals only. So this is a constant, and constants about live
  # rosters go stale — a starter gets hurt in week 2 and this list is wrong until
  # someone edits it. That is acceptable for a placeholder (nothing branches on
  # it, and a retired starter is still a real first name) but it is the reason
  # this lives in ONE named place instead of being sprinkled through a view.
  #
  # Duplicates are fine and not deduped: two Joshes make Josh twice as likely,
  # which is a fair reflection of how common the name is.
  QB_FIRST_NAMES = %w[
    Jacoby Tua Lamar Josh Bryce Caleb Joe Shedeur
    Dak Bo Patrick Kirk Malik Kyler Geno Aaron
  ].freeze

  # The pool the card samples from. A method rather than the bare constant so a
  # caller (a test, a future engine primitive) has one seam to stub.
  def first_name_placeholder_names
    QB_FIRST_NAMES
  end
end
