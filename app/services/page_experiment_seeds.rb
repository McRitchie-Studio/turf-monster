# The experiments this app ships as data, made idempotently. The production
# path is `bin/rails experiments:seed_turf_monster_v2` (lib/tasks/experiments.rake)
# or the same rows typed into /admin/experiments; never a data migration.
#
# IDEMPOTENT AND NON-CLOBBERING: a second run finds the experiment by slug and
# changes nothing, so copy an operator edited in the admin survives a re-run.
# `reset: true` (the e2e lane's fixture, and a desk) rewrites the variants to
# the copy below and turns the experiment on.
#
# It is created PAUSED unless asked otherwise (`active: true`): the copy waits
# for Alex's approval in the admin before any visitor is split.
module PageExperimentSeeds
  TURF_MONSTER_V2 = {
    slug: "turf-monster-v2",
    name: "Explainer headline: pick'em vs fantasy football",
    page_path: "/turf-monster-v2",
    variants: [
      { key: "control", label: "Control: Pick 6 teams. Stack points. Get paid.", weight: 1, position: 0 },
      { key: "fantasy-football", label: "NFL Team Fantasy Football", weight: 1, position: 1,
        headline: "NFL Team\nFantasy\nFootball",
        subhead_desktop: "Draft 6 NFL teams, not players. Every point they score over the three-week slate counts, " \
                         "times their multiplier. Underdogs score big.",
        subhead_mobile: "Draft 6 NFL teams. Every point counts, times their multiplier.",
        meta_title: "Turf Monster — NFL Team Fantasy Football",
        meta_description: "Fantasy football with NFL teams, not players: draft 6 teams, and every point they score " \
                          "over the three-week slate counts, times their Turf Score. Underdogs carry the bigger multiplier." }
    ]
  }.freeze

  COPY_FIELDS = %i[label headline subhead_desktop subhead_mobile meta_title meta_description].freeze

  def self.turf_monster_v2!(active: false, reset: false)
    spec = TURF_MONSTER_V2
    experiment = PageExperiment.includes(:variants).find_by(slug: spec[:slug])
    return experiment if experiment && !reset

    PageExperiment.transaction do
      experiment ||= PageExperiment.new(slug: spec[:slug], active: false)
      experiment.assign_attributes(name: spec[:name], page_path: spec[:page_path])
      experiment.active = true if active || reset
      spec[:variants].each do |attrs|
        variant = experiment.variants.find { |v| v.key == attrs[:key] } || experiment.variants.build(key: attrs[:key])
        variant.assign_attributes(COPY_FIELDS.index_with(nil).merge(attrs.except(:key)))
      end
      experiment.save!
    end
    experiment
  end
end
