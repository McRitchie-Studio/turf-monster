# Propshaft writes no .gz beside an asset (Sprockets did). These hooks restore
# that, so ActionDispatch::Static keeps serving CSS and JS pre-encoded; without
# them Static would serve them uncompressed, since it answers before
# Rack::Deflater is reached. lib/precompressed_assets.rb.
require Rails.root.join("lib/precompressed_assets").to_s

namespace :assets do
  desc "Write a .gz beside each digested css and js in public/assets"
  task precompress: :environment do
    written = PrecompressedAssets.write(Rails.application.config.assets.output_path)
    puts "precompressed #{written.size} asset(s)"
  end

  desc "Delete .gz files in public/assets whose source asset is gone"
  task prune_precompressed: :environment do
    PrecompressedAssets.prune(Rails.application.config.assets.output_path)
  end
end

Rake::Task["assets:precompile"].enhance { Rake::Task["assets:precompress"].invoke }
Rake::Task["assets:clean"].enhance { Rake::Task["assets:prune_precompressed"].invoke }
