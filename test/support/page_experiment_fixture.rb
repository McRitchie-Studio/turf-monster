# Builds the /turf-monster-v2 experiment the page A/B tests share: a control
# that overrides nothing and a fantasy-football arm with every copy field set.
module PageExperimentFixture
  def create_page_experiment(slug: "turf-monster-v2", page_path: "/turf-monster-v2", active: true,
                             weights: { "control" => 1, "fantasy-football" => 1 })
    PageExperiment.create!(
      slug: slug, name: "Headline test", page_path: page_path, active: active,
      variants_attributes: [
        { key: "control", weight: weights.fetch("control"), position: 0 },
        { key: "fantasy-football", weight: weights.fetch("fantasy-football"), position: 1,
          headline: "NFL Team\nFantasy\nFootball",
          subhead_desktop: "Draft 6 NFL teams, not players. Desktop variant subhead.",
          subhead_mobile: "Draft 6 NFL teams. Mobile variant subhead.",
          meta_title: "Turf Monster — NFL Team Fantasy Football",
          meta_description: "Variant meta description." }
      ]
    )
  end
end
