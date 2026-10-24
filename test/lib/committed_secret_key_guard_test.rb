# frozen_string_literal: true

require "test_helper"
require "json"

# turf-monster is a PUBLIC repository. Mack's devnet signing key (foUu…) was
# committed as a string literal in e2e/devnet-smoke.spec.js on 2026-04-12 and
# found on 2026-10-24; it was evicted from the devnet vault and retired
# (task rotate-leaked-devnet-mack-key). This guard fails CI the next time any
# tracked file holds a Solana secret key. Scanner and its rules:
# lib/turf_monster/committed_secret_scan.rb. Exemptions:
# config/committed_secret_key_allowlist.yml.
#
# Every key below is generated at run time, so this file holds none.
class CommittedSecretKeyGuardTest < ActiveSupport::TestCase
  Scan = TurfMonster::CommittedSecretScan

  def keypair_bytes
    key = OpenSSL::PKey.generate_key("ED25519")
    key.raw_private_key + key.raw_public_key
  end

  # --- the scanner -----------------------------------------------------------

  test "finds a base58 secret key in a JS string literal, by line, naming only the public key" do
    bytes = keypair_bytes
    secret = Scan.encode_base58(bytes)
    text = %(// Mack's wallet\nconst MACK_KEY = "#{secret}";\n)

    findings = Scan.scan_text("e2e/x.spec.js", text)

    assert_equal 1, findings.size
    f = findings.first
    assert_equal 2, f.line
    assert_equal "base58", f.form
    assert_equal Scan.encode_base58(bytes.byteslice(32, 32)), f.pubkey
    refute_includes f.to_s, secret, "a finding must never echo the secret"
  end

  test "finds a solana-keygen byte array, compact or spread over lines" do
    bytes = keypair_bytes
    compact = JSON.generate(bytes.bytes)
    spread = "[\n  #{bytes.bytes.join(",\n  ")},\n]"

    assert_equal ["byte array"], Scan.scan_text("k.json", compact).map(&:form)
    assert_equal ["byte array"], Scan.scan_text("k.rb", "KEY = #{spread}").map(&:form)
  end

  test "a transaction signature is 64 bytes of base58 too, and is not a finding" do
    signature = Scan.encode_base58(OpenSSL::Random.random_bytes(64))
    assert_operator signature.size, :>=, 85

    assert_empty Scan.scan_text("docs/runbook.md", "| EVICT | `#{signature}` |")
  end

  test "64 integers that are not a keypair, or not bytes, are not a finding" do
    assert_empty Scan.scan_text("a.json", JSON.generate(OpenSSL::Random.random_bytes(64).bytes))
    assert_empty Scan.scan_text("b.json", JSON.generate(Array.new(64) { 300 }))
  end

  test "a public key alone is not a finding" do
    assert_empty Scan.scan_text("c.yml", "address: #{Scan.encode_base58(keypair_bytes.byteslice(32, 32))}")
  end

  # --- the guard -------------------------------------------------------------

  test "no tracked file holds a Solana secret key outside the allow-list" do
    root = Rails.root
    paths = Scan.tracked_paths(root)
    assert_operator paths.size, :>, 500, "the scan must cover the repository, not a handful of files"
    assert_includes paths, "e2e/devnet-smoke.spec.js"

    allowed = Scan.allowlist(root)
    leaks = Scan.scan_tracked(root).reject { |f| allowed.key?(f.pubkey) }

    assert_empty leaks, <<~MSG
      Solana secret key(s) committed to this PUBLIC repository:
        #{leaks.map(&:to_s).join("\n  ")}
      Move the secret to an environment variable (1Password -> GitHub secret or
      app config) and ROTATE the key: once pushed it is published, and git history
      keeps it. Only a throwaway fixture key may instead be listed, by public key,
      in #{Scan::ALLOWLIST_PATH}.
    MSG
  end

  test "every allow-list entry still matches a key the scan finds" do
    root = Rails.root
    found = Scan.scan_tracked(root).map(&:pubkey)
    stale = Scan.allowlist(root).keys - found

    assert_empty stale, "#{Scan::ALLOWLIST_PATH} exempts key(s) no tracked file holds: #{stale.join(', ')}"
  end
end
