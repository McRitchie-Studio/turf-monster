# Receives the strict script policy's violation reports (SigningCsp's
# report-uri) and keeps each as an ErrorLog row, read at /admin/error_logs.
# Report-only is how the signing pages' policy is rehearsed on QA, and a
# report the browser sends nowhere is a rehearsal nobody can read.
#
# ActionController::Base, like WalletProbeController: a browser posts here on
# its own, with no session or CSRF token, and the app's filter chain (geo,
# profile completion, allow_browser) would answer it with a redirect.
class CspReportsController < ActionController::Base
  skip_forgery_protection

  MAX_BODY = 8.kilobytes
  MAX_REPORTS = 5
  # report-uri's field => the Reporting API's name for it.
  FIELDS = {
    "document-uri" => "documentURL", "violated-directive" => "effectiveDirective",
    "effective-directive" => "effectiveDirective", "blocked-uri" => "blockedURL", "source-file" => "sourceFile",
    "line-number" => "lineNumber", "script-sample" => "sample", "disposition" => "disposition"
  }.freeze

  rate_limit to: 30, within: 1.minute, with: -> { head :too_many_requests }

  def create
    body = request.body.read(MAX_BODY + 1).to_s
    return head(:content_too_large) if body.bytesize > MAX_BODY

    reports(body).first(MAX_REPORTS).each { |report| record(report) }
    head :no_content
  end

  private

  # report-uri sends {"csp-report": {...}}; the Reporting API sends
  # [{"type": "csp-violation", "body": {...}}] with camelCase keys.
  def reports(body)
    parsed = JSON.parse(body)
    case parsed
    when Hash then [ parsed["csp-report"] ].compact
    when Array then parsed.filter_map { |item| item["body"] if item.is_a?(Hash) && item["type"] == "csp-violation" }
    else []
    end.select { |report| report.is_a?(Hash) }
  rescue JSON::ParserError
    []
  end

  def record(report)
    fields = FIELDS.to_h { |name, api_name| [ name, (report[name] || report[api_name]).to_s[0, 300] ] }.compact_blank
    log = ErrorLog.create!(
      message: "CSP #{fields['disposition'] || 'report'}: #{fields['effective-directive'] || fields['violated-directive']} " \
               "blocked #{fields['blocked-uri']} on #{fields['document-uri']}"[0, 500],
      inspect: fields.to_json,
      parent_name: "csp-report"
    )
    log.update_column(:slug, "error-log-#{log.id}")
  end
end
