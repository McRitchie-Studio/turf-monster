# frozen_string_literal: true

require "test_helper"

# [unit] UserSeedsSnapshot had no caller, and stimulus-rails had no controller
# or pin; both are removed. This keeps a stray reference from loading either back.
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

  test "nothing pins, imports or mounts Stimulus" do
    assert_empty hits([Rails.root.join("config/importmap.rb").to_s] + files_under("app/javascript"), /stimulus/i)
    assert_empty hits(files_under("app/views", ext: "*.erb"), /data-controller=/)
    assert_no_match(/^\s*gem "stimulus-rails"/, Rails.root.join("Gemfile").read)
  end
end
