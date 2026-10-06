# Page A/B tests shipped as data (PageExperimentSeeds). Idempotent: a second run
# changes nothing, so an operator's admin edits survive it.
#
#   bin/rails experiments:seed_turf_monster_v2            # create, PAUSED
#   ACTIVE=1 bin/rails experiments:seed_turf_monster_v2   # create, running
#
# Binding a short link (e.g. /l/tt) to it is an admin step, at
# /admin/short_links, once the copy is approved.
namespace :experiments do
  desc "Create the /turf-monster-v2 headline experiment (control vs fantasy-football), paused unless ACTIVE=1"
  task seed_turf_monster_v2: :environment do
    experiment = PageExperimentSeeds.turf_monster_v2!(active: ENV["ACTIVE"] == "1")
    state = experiment.active? ? "running" : "paused"
    puts "#{experiment.slug} on #{experiment.page_path}: #{state}, variants #{experiment.variants.map(&:key).join(', ')}"
  end
end
