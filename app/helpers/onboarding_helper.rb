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

  # --- the engine card's copy, and the locals both layouts pass it ------------

  # THE SUBTEXT IS TURF'S OWN, NOT THE GEM'S DEFAULT, and that is deliberate.
  # studio-engine's first-name card defaults to a SHORTER line ("...we use it to
  # address you in emails."). Turf has always named what the emails are about,
  # and the entry-gate variant has always said WHY it is asking now. Letting the
  # gem default win would have quietly dropped both clauses in an adoption whose
  # whole job was to change nothing a user sees, so both strings are carried
  # across verbatim from the deleted app/views/modals/_onboarding.html.erb.
  FIRST_NAME_SUBTEXT_CHAIN =
    "Just your first name — we use it to address you in emails about your contests and payouts.".freeze
  FIRST_NAME_SUBTEXT_REQUIRED =
    "One last thing before your entry — just your first name, so we can address you " \
    "in emails about your contests and payouts.".freeze

  # Locals for studio/modals/onboarding/first_name, shared by every host
  # registration of that card — which today is the two in layouts/application
  # (skippable and required), and until 2026-09-09 was also the pair in
  # layouts/modal_preview. Those were SEPARATE lists by design, so a value
  # written inline was written twice and free to drift; the same is true of the
  # two branches below, which is why the helper still earns its place with one
  # layout left. Same seam web3_step_up_locals provides for that card, and an
  # inline copy is exactly where the wallet card drifted before.
  #
  # `required` hides both skip affordances. The gem resolves it at RENDER time
  # rather than from the Alpine store, which is why the layouts register two
  # branches keyed on the caller's prop instead of one card — see the
  # registration comment in layouts/application.html.erb.
  #
  # NOT PASSED, because each gem default is already character-identical to the
  # markup this replaced: heading ("What should we call you?"), max_length
  # (Studio::FULL_NAME_MAX_LENGTH), submit_path, skip_path, the field id and
  # done_event. onboarding_gallery_test pins the rendered heading so a future gem
  # default cannot move turf's copy in silence.
  def first_name_modal_locals(required: false)
    {
      required: required,
      # Step 1 of the chain: first name (1) -> age (2) -> wallet (3), per the
      # operator's call on 2026-08-19. The other two cards render 2 and 3 of 3.
      progress: [ 1, 3 ],
      placeholder_names: first_name_placeholder_names,
      subtext: required ? FIRST_NAME_SUBTEXT_REQUIRED : FIRST_NAME_SUBTEXT_CHAIN
    }
  end
end
