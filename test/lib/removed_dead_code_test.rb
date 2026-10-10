# frozen_string_literal: true

require "test_helper"

# [unit] UserSeedsSnapshot had no caller, and stimulus-rails had no controller
# or pin; both are removed. This keeps a stray reference from loading either back.
# The app's own controllers (app/javascript/turf_stimulus.js) import the engine's
# vendored Stimulus, so the gem and a pin of its own stay out.
class RemovedDeadCodeTest < ActiveSupport::TestCase
  def files_under(*dirs, ext: "*")
    dirs.flat_map { |dir| Dir[Rails.root.join(dir, "**", ext).to_s] }.select { |path| File.file?(path) }
  end

  def hits(paths, pattern)
    paths.reject { |path| path == __FILE__ }.select { |path| File.read(path).match?(pattern) }
  end

  test "the snapshot service is gone and no Ruby file names it" do
    assert_not Rails.root.join("app/services/user_seeds_snapshot.rb").exist?
    assert_empty hits(files_under("app", "lib", "config", "bin", "test", ext: "*.rb"),
                      /UserSeedsSnapshot|user_seeds_snapshot/)
  end

  test "the app bundles and pins no Stimulus of its own" do
    assert_no_match(/^\s*gem "stimulus-rails"/, Rails.root.join("Gemfile").read)
    assert_no_match(/^\s*pin\s+"@hotwired\/stimulus/, Rails.root.join("config/importmap.rb").read)
    assert_empty hits(files_under("app/javascript"), /stimulus-loading|stimulus\.min/)
  end
end
