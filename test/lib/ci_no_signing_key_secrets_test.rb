require "test_helper"

# No signing key lives in CI (task turf-ci-drops-admin-key-secret).
#
# Until 2026-10-24 the test and playwright jobs read a throwaway
# SOLANA_ADMIN_KEY repository secret. It was deleted; Solana::Keypair.admin now
# takes its Rails.env.test? fallback (TEST_ADMIN_SEED) on every CI run, as
# Dependabot PRs always did (test/services/solana/keypair_admin_fallback_test.rb).
# A Solana key in a GitHub secret is a key anyone with workflow-edit access can
# exfiltrate, so this guard fails if any workflow or action under .github/ reads
# a secret whose name looks like a signing key: SOLANA_*KEY* or *PRIVATE*KEY*.
# It also refuses toJSON(secrets) and a computed secrets[...] index, the two
# ways to read a secret without naming it. GitHub secret names are
# case-insensitive, so the match is too.
class CiNoSigningKeySecretsTest < ActiveSupport::TestCase
  GITHUB_DIR = Rails.root.join(".github")

  SIGNING_KEY_NAME = /\A(?:SOLANA_.*KEY|.*PRIVATE.*KEY)/i

  # secrets.NAME, secrets['NAME'], secrets["NAME"]
  NAMED_READ = /\bsecrets\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_]*)|\[\s*['"]([^'"]+)['"]\s*\])/
  # toJSON(secrets) or secrets[<expression>]: a read that names nothing
  UNNAMED_READ = /toJSON\(\s*secrets\s*\)|\bsecrets\s*\[\s*(?!['"])/i

  def self.secret_names(text)
    text.scan(NAMED_READ).map { |dot, bracket| dot || bracket }
  end

  def self.violations(text)
    names = secret_names(text).grep(SIGNING_KEY_NAME).uniq
    names << "(unnamed secrets read)" if text.match?(UNNAMED_READ)
    names
  end

  def workflow_files
    Dir.glob(GITHUB_DIR.join("**", "*.{yml,yaml}").to_s).sort
  end

  test "no workflow or action under .github reads a signing-key secret" do
    files = workflow_files
    assert files.any? { |f| f.end_with?("workflows/ci.yml") },
      "the scan must cover .github/workflows/ci.yml, or it proves nothing"

    offenders = files.filter_map do |path|
      found = self.class.violations(File.read(path))
      "#{path.delete_prefix("#{Rails.root}/")}: #{found.join(", ")}" if found.any?
    end

    assert_empty offenders,
      "A workflow reads a signing-key secret. No signing key lives in CI: " \
      "Solana::Keypair.admin falls back to TEST_ADMIN_SEED under Rails.env.test?.\n" \
      "#{offenders.join("\n")}"
  end

  # --- controls: the scan sees real secrets, and the matcher fires -----------

  test "control: the scanner reads the secret ci.yml does use" do
    names = workflow_files.flat_map { |f| self.class.secret_names(File.read(f)) }
    assert_includes names, "RAILS_MASTER_KEY",
      "the scanner must find RAILS_MASTER_KEY in ci.yml; if it cannot, the guard above is blind"
  end

  test "control: the matcher flags the removed line and its look-alikes" do
    [
      "      SOLANA_ADMIN_KEY: ${{ secrets.SOLANA_ADMIN_KEY }}",
      "      KEY: ${{ secrets.solana_cosigner_keys }}",
      "      K: ${{ secrets['SOLANA_DEPLOY_KEYPAIR'] }}",
      "      K: ${{ secrets[\"VAULT_PRIVATE_KEY\"] }}",
      "      K: ${{ secrets.DEPLOYER_PRIVATE_KEY_B58 }}",
      "      ALL: ${{ toJSON(secrets) }}",
      "      K: ${{ secrets[format('{0}_KEY', 'SOLANA_ADMIN')] }}"
    ].each do |line|
      assert self.class.violations(line).any?, "guard must flag: #{line.strip}"
    end
  end

  test "control: the matcher passes secrets that are not signing keys" do
    [
      "      RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}",
      "      TOKEN: ${{ secrets.GITHUB_TOKEN }}",
      "      URL: ${{ secrets.SOLANA_RPC_URL }}",
      "      SOLANA_ADMIN_KEY: ''"
    ].each do |line|
      assert_empty self.class.violations(line), "guard must pass: #{line.strip}"
    end
  end
end
