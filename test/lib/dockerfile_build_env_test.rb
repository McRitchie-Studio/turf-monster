require "test_helper"

# [unit] The Dockerfile's asset-precompile line boots the app as production, and
# a production boot refuses to start without its R2 connection
# (StorageBackend.verify!), its managed-wallet key and its Solana settings. The
# line names build-time placeholders for them. These tests pin the two halves
# of that bargain: the placeholders satisfy the storage check, and they can
# never reach a running container, which must still hold the real values or
# refuse to boot. Heroku builds with the Ruby buildpack and never reads this
# file; the Dockerfile is for a container build.
class DockerfileBuildEnvTest < ActiveSupport::TestCase
  DOCKERFILE = Rails.root.join("Dockerfile")
  BOOT_GUARDED = (StorageBackend::R2_VARIABLES +
                  %w[MANAGED_WALLET_ENCRYPTION_KEY SOLANA_PROGRAM_ID SOLANA_RPC_URL SOLANA_NETWORK]).freeze

  test "the precompile line names a placeholder for every variable a production boot requires" do
    assert_equal BOOT_GUARDED.sort, (precompile_env.keys & BOOT_GUARDED).sort
  end

  test "the placeholders pass the storage check a production boot runs" do
    assert StorageBackend.verify!(precompile_env, production: true)
  end

  test "every placeholder URL points at a host that never resolves" do
    urls = precompile_env.values.grep(%r{\Ahttps?://})
    assert_not_empty urls
    urls.each { |url| assert URI(url).host.end_with?(".invalid"), "#{url} could resolve" }
  end

  test "no ENV or ARG instruction carries a placeholder into the running image" do
    instructions = DOCKERFILE.read.lines.grep(/\A\s*(ENV|ARG)\s/)
    BOOT_GUARDED.each do |name|
      assert_empty instructions.grep(/\b#{name}\b/), "#{name} must be set on the precompile RUN line only"
    end
  end

  # The real boot cannot skip the check: SECRET_KEY_BASE_DUMMY, which the build
  # sets, is no exemption, and production without the R2 variables raises.
  test "a production boot without the R2 variables still raises, dummy secret or not" do
    [ {}, { "SECRET_KEY_BASE_DUMMY" => "1" } ].each do |env|
      error = assert_raises(ArgumentError) { StorageBackend.verify!(env, production: true) }
      assert_match(/R2_ENDPOINT must be set/, error.message)
    end
  end

  private

  # The VAR=value assignments on the RUN line that precompiles assets.
  def precompile_env
    run = DOCKERFILE.read[/^RUN\b(?:[^\n]*\\\n)*[^\n]*assets:precompile[^\n]*$/]
    assert run, "no RUN line runs assets:precompile in the Dockerfile"
    run.gsub("\\\n", " ").scan(/\b([A-Z][A-Z0-9_]*)=(\S+)/).to_h
  end
end
