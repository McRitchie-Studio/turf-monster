# What the server tells a model about itself in the `initialize` result. A
# client may put this in front of the model for the whole conversation, so it is
# the one place to say how the game is played and what must not be done without
# the player's word.
module AgentMcp
  INSTRUCTIONS = [
    <<~TEXT,
      Turf Monster is a sports pick'em game. A contest has a board of teams; the
      player enters by picking a fixed number of them (picks_required, normally
      six). Each pick scores the team's real points or goals times its turf_score
      multiplier, and the entry's score is the sum. Strong offenses have low
      multipliers and weak ones high, so a lineup is a trade between likely points
      and price. The best scores win the prizes.
    TEXT
    "Call the tools in this order.",
    <<~TEXT,
      1. get_me: check wallet.kind is "managed" (otherwise the player must enter
      on turfmonster.media) and read free_entry_tokens.
    TEXT
    <<~TEXT,
      2. list_contests with status "open", then get_contest for the one the
      player wants. Its teams list is the board: use only teams whose locked is
      false, and take each pick's matchup_id from there.
    TEXT
    <<~TEXT,
      3. Propose a lineup and CONFIRM IT WITH THE PLAYER before submitting. An
      entry spends a free entry token, or money, and cannot be undone or refunded.
    TEXT
    <<~TEXT,
      4. submit_entry with the contest_slug, the matchup_ids and an
      idempotency_key you make up (a UUID).
    TEXT
    <<~TEXT,
      5. list_my_entries, get_entry and get_leaderboard to follow scores, rank
      and winnings. edit_entry replaces the picks of an entry until the contest
      locks.
    TEXT
    <<~TEXT,
      Token only: leave allow_usdc false unless the player has told you, in this
      conversation, to pay the entry fee in USDC. If submit_entry answers
      no_entry_token, tell the player and ask; do not turn allow_usdc on yourself.
    TEXT
    <<~TEXT,
      The retry rule: one entry, one idempotency_key. If submit_entry times out,
      fails with chain_unavailable, idempotency_in_progress or internal_error, or
      answers pending, call it again with the SAME idempotency_key and the same
      arguments; the server then returns the one entry instead of paying twice.
      Use a new key only for a different entry, or after changing the picks or
      allow_usdc.
    TEXT
    <<~TEXT
      A tool result is JSON. A failure has isError true and
      {"error": {"code", "message"}}: branch on code, and show message to the
      player. account_frozen and age_verification_required are for the player to
      resolve on the website. Times are UTC; money is integer cents.
    TEXT
  ].map(&:squish).join("\n").freeze
end
