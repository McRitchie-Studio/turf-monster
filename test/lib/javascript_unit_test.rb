require "test_helper"
require "open3"

# [unit] Runs the node:test files in test/javascript inside the Rails suite, so
# CI's `test` job runs them with no lane of its own.
class JavascriptUnitTest < ActiveSupport::TestCase
  FILES = Rails.root.join("test/javascript/*.test.mjs")
  LOGIC = Rails.root.join("app/javascript/turf/*.js")

  test "the JavaScript unit tests pass" do
    files = Dir[FILES].sort
    assert_not_empty files

    output, status = Open3.capture2e("node", "--test", "--test-reporter=tap", *files)

    assert status.success?, output
    assert_match(/^# pass [1-9]/, output, "node ran no test")
    assert_match(/^# fail 0$/, output)
  end

  test "every logic module has a test file and imports nothing" do
    Dir[LOGIC].sort.each do |path|
      name = File.basename(path, ".js")
      assert File.exist?(Rails.root.join("test/javascript/#{name}.test.mjs")), "app/javascript/turf/#{name}.js has no test/javascript/#{name}.test.mjs"
      assert_no_match(/^\s*import\b/, File.read(path), "#{name}.js imports a module, which test/javascript/support/load.mjs cannot follow")
    end
  end
end
