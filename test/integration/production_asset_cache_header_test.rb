# frozen_string_literal: true

require "test_helper"

# [integration] PRODUCTION SERVES DIGESTED ASSETS WITH A YEAR OF CACHING
# (task: turf-every-visitor-lang-main-cache; audit 2026-10-24, lane UI P2).
#
# production.rb set no public_file_server.headers, so ActionDispatch::Static
# served /assets/* with no Cache-Control and every page re-requested its
# 119-126 assets (measured on /contests). A digested filename changes when its
# content does, so a year is safe.
#
# WHY NOT A REQUEST AGAINST THIS APP. The test env sets its own one-hour header
# (config/environments/test.rb) and Propshaft serves assets itself here with its
# own header, so a plain `get "/assets/…"` measures neither production setting.
# Booting the production env needs its credentials and Redis, which a test run
# does not have. So this test takes the headers production.rb assigns —
# evaluated from the file, the one place they live — and serves a real
# digested-named file through the same middleware production runs.
class ProductionAssetCacheHeaderTest < ActiveSupport::TestCase
  PRODUCTION_RB = Rails.root.join("config/environments/production.rb")
  ASSIGNMENT    = /^\s*config\.public_file_server\.headers\s*=\s*(\{.*\})\s*$/

  def production_headers
    lines = PRODUCTION_RB.read.lines.grep(ASSIGNMENT)
    assert_equal 1, lines.size, "production.rb must assign public_file_server.headers exactly once, uncommented"
    eval(lines.first[ASSIGNMENT, 1]) # rubocop:disable Security/Eval -- our own config file, not input
  end

  test "[integration] a digested asset request carries a one-year public cache-control" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "assets"))
      File.write(File.join(root, "assets/application-0123456789abcdef.css"), "body{}")
      inner  = ->(_env) { [404, {}, ["not served statically"]] }
      static = ActionDispatch::Static.new(inner, root, headers: production_headers)

      response = Rack::MockRequest.new(static).get("/assets/application-0123456789abcdef.css")

      assert_equal 200, response.status
      assert_equal "public, max-age=#{1.year.to_i}", response.headers["cache-control"]
    end
  end
end
