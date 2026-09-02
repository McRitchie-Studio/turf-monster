require "test_helper"
require "minitest/mock"

# Solana::Keypair.admin is the Alex Bot signer: 1-of-3 on the turf-vault
# multisig and the fee payer/signer for create_contest, enter_contest and
# mint_entry_token. Its absence MUST stay a hard raise everywhere except test.
#
# Why the test-env fallback exists: SOLANA_ADMIN_KEY (and the RAILS_MASTER_KEY
# that decrypts credentials.secret_key_base) are GitHub *repository* secrets.
# Dependabot pull requests run against the separate Dependabot secret store and
# cannot read repository secrets by design, so every dependency PR on this repo
# failed these same unit tests permanently. The unit tests only assemble and
# encrypt -- they never reach the network or a funded account -- so requiring a
# production credential to run them was the defect.
#
# These tests exist to prove the escape hatch is exactly one environment wide.
class Solana::KeypairAdminFallbackTest < ActiveSupport::TestCase
  # .admin memoizes into @admin, and the encryptors into @legacy_encryptor /
  # @current_encryptor. Every test here MUST clear them: a sibling test that ran
  # earlier in this process may already have populated them, and `||=` would
  # then short-circuit past the branch under test -- the assertion would pass
  # green without ever executing the code it claims to cover.
  def without_memoized(*ivars)
    previous = ivars.to_h { |n| [n, Solana::Keypair.instance_variable_get(n)] }
    ivars.each { |n| Solana::Keypair.instance_variable_set(n, nil) }
    yield
  ensure
    previous&.each { |n, v| Solana::Keypair.instance_variable_set(n, v) }
  end

  # dotenv loads .env in dev AND test, and .env sets SOLANA_ADMIN_KEY, so the
  # ambient shell must be controlled or these tests measure the developer's
  # machine rather than the code. (CI's unit job exports it too.)
  def with_admin_key(value)
    had = ENV.key?("SOLANA_ADMIN_KEY")
    previous = ENV["SOLANA_ADMIN_KEY"]
    value.nil? ? ENV.delete("SOLANA_ADMIN_KEY") : ENV["SOLANA_ADMIN_KEY"] = value
    yield
  ensure
    had ? ENV["SOLANA_ADMIN_KEY"] = previous : ENV.delete("SOLANA_ADMIN_KEY")
  end

  def as_env(name, &block)
    Rails.stub(:env, ActiveSupport::StringInquirer.new(name), &block)
  end

  # --- the fallback itself ----------------------------------------------------

  test "admin falls back to a usable deterministic keypair in test when the env var is absent" do
    first = second = nil
    without_memoized(:@admin) { with_admin_key(nil) { first = Solana::Keypair.admin } }
    without_memoized(:@admin) { with_admin_key(nil) { second = Solana::Keypair.admin } }

    assert_equal 32, first.public_key_bytes.bytesize, "fallback must be a real ed25519 keypair"
    assert_equal first.to_base58, second.to_base58, "fallback must be deterministic across processes"
    assert first.sign("turf"), "fallback must actually be able to sign"
  end

  test "admin prefers a configured SOLANA_ADMIN_KEY over the test fallback" do
    configured = Solana::Keypair.generate
    fallback = nil
    loaded = nil

    without_memoized(:@admin) { with_admin_key(nil) { fallback = Solana::Keypair.admin.to_base58 } }
    without_memoized(:@admin) do
      with_admin_key(Solana::Keypair.encode_base58(configured.to_bytes)) do
        loaded = Solana::Keypair.admin
      end
    end

    assert_equal configured.to_base58, loaded.to_base58,
                 "a supplied key must still win -- the fallback must never mask a configured signer"
    assert_not_equal fallback, loaded.to_base58
  end

  # --- THE GUARD: unreachable outside test ------------------------------------

  test "admin still raises outside the test environment when the env var is absent" do
    %w[production development staging].each do |env_name|
      without_memoized(:@admin) do
        with_admin_key(nil) do
          as_env(env_name) do
            error = assert_raises(RuntimeError, "#{env_name} must NOT get a fallback signer") do
              Solana::Keypair.admin
            end
            assert_match(/SOLANA_ADMIN_KEY env var required/, error.message)
          end
        end
      end
    end
  end

  test "admin raises in production even when the test fallback constant is present" do
    # Guards the shape of the fix: the constant existing must never be enough --
    # only Rails.env.test? may reach it.
    assert Solana::Keypair::TEST_ADMIN_SEED.present?

    without_memoized(:@admin) do
      with_admin_key(nil) do
        as_env("production") { assert_raises(RuntimeError) { Solana::Keypair.admin } }
      end
    end
  end

  # --- the same guard on the legacy managed-wallet key ------------------------

  test "legacy managed-wallet decryption raises outside test when secret_key_base is unavailable" do
    legacy = with_admin_key(nil) do
      enc = ActiveSupport::MessageEncryptor.new(
        (Rails.application.credentials.secret_key_base.presence ||
          Solana::Keypair::TEST_SECRET_KEY_BASE)[0, 32]
      )
      enc.encrypt_and_sign(Base64.strict_encode64(Solana::Keypair.generate.to_bytes))
    end

    without_memoized(:@legacy_encryptor, :@current_encryptor) do
      Rails.application.credentials.stub(:secret_key_base, nil) do
        as_env("production") do
          error = assert_raises(RuntimeError) { Solana::Keypair.from_encrypted(legacy) }
          assert_match(/RAILS_MASTER_KEY required/, error.message,
                       "a missing master key must surface as a credential error, not `nil[]`")
        end
      end
    end
  end
end
