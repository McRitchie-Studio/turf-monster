require "test_helper"

# [integration] CspReportsController: the strict script policy's reports land
# in ErrorLog, in both shapes a browser sends, with no session or CSRF token,
# bounded in size and count.
class CspReportsControllerTest < ActionDispatch::IntegrationTest
  def post_report(body, type)
    post "/csp_reports", params: body, headers: { "CONTENT_TYPE" => type }
  end

  def report_uri_body
    { "csp-report" => { "document-uri" => "https://turf.test/contests/x", "violated-directive" => "script-src-elem",
                        "effective-directive" => "script-src-elem", "blocked-uri" => "inline",
                        "script-sample" => "window.injected = 1", "disposition" => "report" } }.to_json
  end

  test "a report-uri report becomes an ErrorLog row naming what was blocked and where" do
    assert_difference -> { ErrorLog.where(parent_name: "csp-report").count }, 1 do
      post_report(report_uri_body, "application/csp-report")
    end
    assert_response :no_content
    log = ErrorLog.where(parent_name: "csp-report").last
    assert_match %r{CSP report: script-src-elem blocked inline on https://turf.test/contests/x}, log.message
    assert_equal "window.injected = 1", JSON.parse(log.inspect_field)["script-sample"]
    assert_equal "error-log-#{log.id}", log.slug
  end

  test "the same report again inside the window adds no row" do
    assert_difference -> { ErrorLog.where(parent_name: "csp-report").count }, 1 do
      3.times { post_report(report_uri_body, "application/csp-report") }
    end
    travel(CspReportsController::DEDUPE_WINDOW + 1.minute) { post_report(report_uri_body, "application/csp-report") }
    assert_equal 2, ErrorLog.where(parent_name: "csp-report").count
  end

  test "a Reporting API batch keeps only its csp-violation bodies" do
    batch = [ { "type" => "csp-violation", "body" => { "documentURL" => "https://turf.test/account", "effectiveDirective" => "script-src-attr",
                                                       "blockedURL" => "inline", "disposition" => "enforce" } },
              { "type" => "deprecation", "body" => { "id" => "x" } } ].to_json
    assert_difference -> { ErrorLog.where(parent_name: "csp-report").count }, 1 do
      post_report(batch, "application/reports+json")
    end
    assert_match(/CSP enforce: script-src-attr/, ErrorLog.last.message)
  end

  test "junk, an oversize body and a flood are refused without a row" do
    assert_no_difference -> { ErrorLog.count } do
      post_report("not json", "application/csp-report")
      assert_response :no_content
      post_report({ "csp-report" => { "script-sample" => "x" * 9000 } }.to_json, "application/csp-report")
      assert_response :content_too_large
    end
    many = Array.new(20) { |i| { "type" => "csp-violation", "body" => { "effectiveDirective" => "script-src", "blockedURL" => "/#{i}" } } }.to_json
    assert_difference -> { ErrorLog.count }, CspReportsController::MAX_REPORTS do
      post_report(many, "application/reports+json")
    end
  end
end
