require "test_helper"

# [unit] SigningCsp.strict and its page list. The strict policy is the app
# policy with script-src narrowed: no 'unsafe-inline', no https:, each
# third-party script named by file, 'unsafe-eval' kept while Alpine runs.
# Every other directive is the app's, and the app policy itself is left
# untouched. And the flip guard: the enforce switch stays off while a gem
# still renders an un-nonced script on a signing page.
class SigningCspUnitTest < ActiveSupport::TestCase
  def app_policy = Rails.application.config.content_security_policy

  def directives(policy) = policy.build(nil, nil, []).split("; ").to_h { |d| [ d.split(" ").first, d.split(" ").drop(1) ] }

  test "script-src drops 'unsafe-inline' and https: and names its hosts" do
    script_src = directives(SigningCsp.strict(app_policy)).fetch("script-src")

    assert_equal [ "'self'", "'unsafe-eval'", "'report-sample'",
                   "https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js",
                   "https://unpkg.com/@solana/web3.js@1.98.4/lib/index.iife.min.js",
                   "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js",
                   "https://cdn.logr-in.com" ], script_src
  end

  # The public npm mirrors are named by file, never by bare host: a bare
  # cdn.jsdelivr.net or unpkg.com admits any package an injected tag names.
  test "no npm mirror is allowed host-wide" do
    script_src = directives(SigningCsp.strict(app_policy)).fetch("script-src")
    mirrors = %w[https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com]

    mirrors.each do |mirror|
      assert_not_includes script_src, mirror
      assert_not_includes script_src, "#{mirror}/"
    end
    assert script_src.grep(%r{\Ahttps://(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)/.+\.js\z}).size == 3
  end

  # Every file the strict list names is one a view or script actually loads,
  # at that exact URL; a version bump that moved the tag would otherwise
  # leave the page loading a file the policy refuses.
  test "each third-party file the strict list names is loaded at that URL" do
    sources = Dir.glob(Rails.root.join("app/{views,javascript}/**/*.{erb,js}")).map { |file| File.read(file) }.join
    sources += [ "studio-engine", "solana-studio" ].map { |gem|
      Dir.glob(File.join(Gem.loaded_specs.fetch(gem).full_gem_path, "app/views/**/*.erb")).map { |file| File.read(file) }.join
    }.join

    Rails.configuration.x.signing_csp_script_src.grep(%r{\Ahttps://[^/]+/.+}).each do |url|
      assert_includes sources, url
    end
  end

  test "every other directive is the app policy's, it reports, and the app policy is unchanged" do
    before = app_policy.build(nil, nil, [])
    strict = directives(SigningCsp.strict(app_policy))
    app = directives(app_policy)

    assert_equal app.except("script-src"), strict.except("script-src", "report-uri")
    assert_equal [ "/csp_reports" ], strict.fetch("report-uri")
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

  # THE FLIP GUARD. Enforcing while a gem still renders an un-nonced script
  # on a signing page refuses it (the wallet picker loses mobile Phantom), and
  # every other test stays green after that flip. This one does not: it reads
  # the switch as configured and the gem fixes open in the locked gems.
  test "the enforce switch stays off while a gem fix is pending" do
    blockers = SigningCsp.enforce_blockers
    assert_empty blockers.map { |fix| "#{fix.gem} #{fix.file}: wait for #{fix.fixed_by}" },
                 "config.x.signing_csp_enforced is on while these gem fixes are open"
  end

  # Its controls: the guard is red for exactly the state it exists to catch.
  test "the guard is red when enforced with a fix open, and only then" do
    open_fix = SigningCsp::PENDING_GEM_FIXES.first

    assert_equal [ open_fix ], SigningCsp.enforce_blockers(enforced: true, pending: [ open_fix ])
    assert_empty SigningCsp.enforce_blockers(enforced: false, pending: [ open_fix ])
    assert_empty SigningCsp.enforce_blockers(enforced: true, pending: [])
  end

  # A pending fix measures its condition in the LOCKED gem's file, so it
  # closes itself when the lock takes the fixed release.
  test "a pending fix is open while the locked gem's file still matches unfixed" do
    fix = SigningCsp::PENDING_GEM_FIXES.first
    source = File.read(File.join(Gem.loaded_specs.fetch(fix.gem).full_gem_path, fix.file))

    assert_equal source.match?(fix.unfixed), fix.open?
    assert SigningCsp::PendingGemFix.new(gem: fix.gem, file: fix.file, unfixed: /window\.startPhantomDeepLink/).open?
    assert_not SigningCsp::PendingGemFix.new(gem: fix.gem, file: fix.file, unfixed: /\Anever-in-this-file\z/).open?
  end
end
