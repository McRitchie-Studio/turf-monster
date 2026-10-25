require "test_helper"
require "yaml"

# [unit] A ceiling of zero on remote scripts the app's own source loads without
# integrity: a static <script src="https://..."> in app/views, or a script
# element whose .src is an https:// literal in a view or in app/javascript
# (RemoteScriptCensus, test/support/remote_script_census.rb). Vendor the file
# (vendor/javascript, or the engine's copy), or pin it with integrity and
# crossorigin as the layout pins web3.js and tweetnacl.
#
# One exemption, and its condition is measured, not trusted: LogRocket's
# recorder loader is an unversioned file its vendor updates in place, so no SRI
# value can pin it. It is excused only while its tag sits inside the layout's
# session_replay_active? guard (production, signed in, not a secret page).
#
# Not counted here: the gems' own views (studio-engine's cropper loads
# cropper.js from cdnjs without integrity; that fix belongs to the engine), and
# the PayPal SDK, whose URL is built at run time and which PayPal does not
# publish an SRI value for.
class RemoteScriptIntegrityCeilingTest < ActiveSupport::TestCase
  CEILINGS_FILE = Pathname(__dir__).join("remote_script_integrity_ceilings.yml")
  LAYOUT = "app/views/layouts/application.html.erb".freeze
  LOGROCKET = "https://cdn.logr-in.com/LogRocket.min.js".freeze
  GUARD = /<%\s*if session_replay_active\?\s*%>\s*\z/

  def self.relative(file) = file.to_s.delete_prefix("#{Rails.root}/")

  def self.exempt?(load)
    relative(load.file) == LAYOUT && load.url == LOGROCKET && load.context.match?(GUARD)
  end

  def self.unpinned(loads = RemoteScriptCensus.loads(RemoteScriptCensus.app_files))
    loads.reject(&:integrity).reject { |load| exempt?(load) }
  end

  test "no remote script loads without integrity, beyond the ceiling" do
    ceiling = YAML.load_file(CEILINGS_FILE).fetch("remote_script_without_integrity")
    found = self.class.unpinned.map { |load| "#{self.class.relative(load.file)}: #{load.url}" }
    assert_equal ceiling, found.size, "remote scripts without integrity:\n  #{found.join("\n  ")}"
  end

  test "the census sees the app's remote scripts, pinned and not" do
    loads = RemoteScriptCensus.loads(RemoteScriptCensus.app_files)
    assert_operator loads.count(&:integrity), :>=, 3, "the layout's web3.js and tweetnacl and wallet_provider's tweetnacl"
    assert loads.any? { |load| self.class.exempt?(load) }, "the LogRocket exemption no longer matches anything; remove it"
  end

  test "the counter sees each spelling and passes over a pinned or quoted one" do
    count = ->(source, extension = ".erb") { self.class.unpinned(RemoteScriptCensus.scan(source, extension)).size }

    assert_equal 1, count.call('<script src="https://cdn.example.com/a.js"></script>')
    assert_equal 1, count.call(%(<script defer\n  src="https://cdn.example.com/a.js"></script>))
    assert_equal 1, count.call('<%= javascript_include_tag "https://cdn.example.com/a.js" %>')
    assert_equal 1, count.call("s.src = 'https://cdn.example.com/a.js';\ndocument.head.appendChild(s);", ".js")
    assert_equal 0, count.call(%(<script src="https://cdn.example.com/a.js"\n  integrity="sha384-abc" crossorigin="anonymous"></script>))
    assert_equal 0, count.call("s.src = 'https://cdn.example.com/a.js';\ns.integrity = 'sha384-abc';", ".js")
    assert_equal 0, count.call('<%# <script src="https://cdn.example.com/a.js"></script> %>')
    assert_equal 0, count.call("  // s.src = 'https://cdn.example.com/a.js';", ".js")
    assert_equal 0, count.call('<%= javascript_include_tag "chart.umd.min" %>')
  end

  test "the LogRocket exemption holds only inside the replay guard" do
    load = ->(context) { RemoteScriptCensus::Load.new(file: Rails.root.join(LAYOUT).to_s, url: LOGROCKET, integrity: false, context:) }

    assert self.class.exempt?(load.call("<% if session_replay_active? %>\n      "))
    assert_not self.class.exempt?(load.call("<% end %>\n      "))
    assert_not self.class.exempt?(RemoteScriptCensus::Load.new(file: Rails.root.join("app/views/help/index.html.erb").to_s,
                                                                url: LOGROCKET, integrity: false, context: "<% if session_replay_active? %>\n"))
  end
end
