require "test_helper"

# [unit] SigningCsp.strict and its page list. The strict policy is the app
# policy with script-src narrowed: no 'unsafe-inline', no https:, each host
# named, 'unsafe-eval' kept while Alpine runs. Every other directive is the
# app's, and the app policy itself is left untouched.
class SigningCspUnitTest < ActiveSupport::TestCase
  def app_policy = Rails.application.config.content_security_policy

  def directives(policy) = policy.build(nil, nil, []).split("; ").to_h { |d| [ d.split(" ").first, d.split(" ").drop(1) ] }

  test "script-src drops 'unsafe-inline' and https: and names its hosts" do
    script_src = directives(SigningCsp.strict(app_policy)).fetch("script-src")

    assert_equal [ "'self'", "'unsafe-eval'", "'report-sample'", "https://cdn.jsdelivr.net", "https://unpkg.com",
                   "https://cdnjs.cloudflare.com", "https://cdn.logr-in.com" ], script_src
  end

  test "every other directive is the app policy's, and the app policy is unchanged" do
    before = app_policy.build(nil, nil, [])
    strict = directives(SigningCsp.strict(app_policy))
    app = directives(app_policy)

    assert_equal app.except("script-src"), strict.except("script-src")
    assert_includes app.fetch("script-src"), "'unsafe-inline'"
    assert_equal before, app_policy.build(nil, nil, [])
  end

  test "the nonce rides script-src alone" do
    header = SigningCsp.strict(app_policy).build(nil, "abc", SigningCsp::NONCE_DIRECTIVES)

    assert_includes header, "'nonce-abc'"
    assert_equal 1, header.scan("'nonce-").size
    assert_match(/script-src [^;]*'nonce-abc'/, header)
  end

  test "the page list names the signing pages and only actions that exist" do
    SigningCsp::PAGES.each do |controller_path, actions|
      controller = "#{controller_path.camelize}Controller".constantize
      actions.each { |action| assert controller.action_methods.include?(action), "#{controller_path}##{action}" }
    end
  end

  test "report-only is the default" do
    assert_not SigningCsp.enforced?
  end
end
