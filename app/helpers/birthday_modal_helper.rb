# View seam for the birthday + age-gate modal pair.
#
# BOTH CARDS ARE THE ENGINE'S. studio-engine 0.60.1 homes them as
# studio/modals/blocks/_birthday (asks) and _age_gate (refuses); this app
# rendered its own copy of the asking half until 2026-08-26. What is left here
# is only the part the engine deliberately refuses to own — this app's legal
# policy and this app's routes.
#
# It is a HELPER rather than literal render calls because the pair is registered
# TWICE: once in layouts/application (what a player meets) and once in
# layouts/modal_preview (the /admin/modals preview harness, which keeps its own
# registration list). Inlining the locals in both is how forks start — the same
# reasoning as Web3StepUpHelper.
module BirthdayModalHelper
  # Locals for `render "studio/modals/blocks/birthday"`.
  #
  # min_age and state are the whole reason this seam exists. The engine hardcodes
  # NO legal policy: it takes a RESOLVED number and a PASSIVE label. This app
  # resolves both from AgePolicy against the SERVER-DETECTED state, never a
  # client-supplied one — a spoofable state must not be able to lower the bar.
  # This app's legal fine print, verbatim from the modals/_age_verify fork this
  # seam replaced. The engine ships only a neutral, policy-free default and
  # documents `fine_print` as the local an app passes its real copy through
  # (studio-engine blocks/_birthday). Threading min_age without it shipped the
  # policy NUMBER and dropped the policy TEXT: the per-state table vanished from
  # the one screen that gates on age, and ENABLE_AGE_GATE suppresses
  # shared/_age_attestation, the only other surface carrying it.
  AGE_FINE_PRINT = "We use your date of birth only to confirm eligibility. " \
                   "Skill-based contest age limits: 18+ most states; " \
                   "19+ AL/NE; 21+ IA/MA/VA.".freeze

  def birthday_modal_locals
    state = geo_state.to_s
    {
      min_age:    AgePolicy.minimum_age(state),
      state:      state,
      submit_url: age_verify_path,
      fine_print: AGE_FINE_PRINT
    }
  end

  # Locals for `render "studio/modals/blocks/age_gate"`.
  #
  # watch_url is the card's whole point: being too young to ENTER is not being
  # too young to WATCH, so the primary CTA is a way to stay rather than a way to
  # leave. The engine drops the CTA entirely when the URL is absent rather than
  # rendering a dead button, so resolving it here is what keeps the refusal from
  # becoming the dead end this card was built to remove.
  #
  # Target follows modals/_username's precedent verbatim — the admin-set main
  # contest, falling back to the index when none is set (off-season, or a fresh
  # deploy with no SeasonConfig row).
  #
  # min_age and state are deliberately NOT passed. The engine falls back to
  # props.minAge / props.state, which the birthday card's own refusal handoff
  # supplies — so the two cards can never disagree about the bar, which they
  # could if each resolved it independently at render time.
  def age_gate_modal_locals
    target = SeasonConfig.main_contest
    { watch_url: target ? contest_path(target) : contests_path }
  end
end
