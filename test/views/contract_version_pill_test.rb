# frozen_string_literal: true

require "test_helper"

# [component] transparency-pins-mainnet-program — the /contract header's version
# pill must not claim a version it could not read.
#
# THE BUG. app/views/contract/show.html.erb fell back to the literal "v0.19"
# whenever Solana::Config.idl_version returned nil or raised. That is a version
# claim made from an error path, and a stale one: by 2026-09-10 both committed
# IDLs read 0.25.0. Unlike the cluster pill beside it, this fallback is SEEN
# when it fires, because the layout reads no IDL: in dev and test a missing IDL
# reaches it, and in production BYPASS_IDL_CHECK=true skips the boot check that
# otherwise guarantees the pinned IDL.
#
# THE HAPPY PATH IS ASSERTED TOO, against the committed IDL rather than a
# literal, so the fix cannot pass by printing "version unknown" all the time.
#
# SCOPED TO A data-test HOOK. The page's playbook copy also mentions versions
# ("v0.19", "v0.18"), so a body-wide match would read those.
class ContractVersionPillTest < ActionDispatch::IntegrationTest
  def version_pill(body)
    body[%r{<span[^>]*data-test="contract-version-pill"[^>]*>(.*?)</span>}m, 1]&.strip
  end

  def assert_pill(expected, why)
    get contract_path
    assert_response :success

    pill = version_pill(response.body)
    assert pill.present?, "the header rendered no version pill - the assertion below would pass vacuously"
    assert_equal expected, pill, why
  end

  test "the pill shows the committed IDL's major.minor" do
    version = JSON.parse(File.read(Solana::Config::IDL_PATH)).dig("metadata", "version")
    assert version.present?, "the committed IDL carries no metadata.version - this case would prove nothing"

    assert_pill "v#{version.split('.').first(2).join('.')}",
      "the pill must track the IDL the app is pinned to"
  end

  test "an IDL that cannot say its version gets no invented one" do
    Solana::Config.stub(:idl_version, nil) do
      assert_pill "version unknown",
        "idl_version returned nil (a missing IDL, or one with no metadata.version); the pill " \
        "must say it does not know rather than print a hard-coded version"
    end
  end

  test "a Solana::Config failure gets no invented version either" do
    raiser = ->(*) { raise NameError, "uninitialized constant Solana::Config" }

    Solana::Config.stub(:idl_version, raiser) do
      assert_pill "version unknown",
        "the view rescues a failed idl_version read; that path must not print a hard-coded version"
    end
  end
end
