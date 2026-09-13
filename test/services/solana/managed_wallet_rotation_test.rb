require "test_helper"

# Solana::ManagedWalletRotation.preflight! — the configurations a rotation must
# refuse BEFORE it reads or writes a single row. Pure: each case hands it an
# env hash, so nothing here touches the process environment or the database.
#
# Every refusal is also checked for the value it refuses: a refusal message is
# printed to an operator's terminal (and a Heroku run log), so it may name the
# RULE a key breaks, never the key.
class Solana::ManagedWalletRotationTest < ActiveSupport::TestCase
  KEY      = Solana::ManagedWalletRotation::KEY_ENV
  PREVIOUS = Solana::ManagedWalletRotation::PREVIOUS_ENV
  Refused  = Solana::ManagedWalletRotation::Refused

  setup do
    @old = SecureRandom.hex(32)
    @new = SecureRandom.hex(32)
  end

  def refusal(env)
    error = assert_raises(Refused) { Solana::ManagedWalletRotation.preflight!(env) }
    [@old, @new, env[KEY], env[PREVIOUS]].compact.map(&:strip).reject(&:empty?).each do |value|
      assert_not error.message.include?(value), "a refusal must never print the key it refuses"
    end
    error.message
  end

  test "a well-formed new key and a distinct previous key is a rotation" do
    assert_equal :rotation, Solana::ManagedWalletRotation.preflight!(KEY => @new, PREVIOUS => @old)
  end

  test "no previous key at all is the legacy-only run, not a refusal" do
    assert_equal :legacy_only, Solana::ManagedWalletRotation.preflight!(KEY => @new)
  end

  test "the PREVIOUS key is not format-checked -- rows opening under it are its only proof" do
    assert_equal :rotation, Solana::ManagedWalletRotation.preflight!(KEY => @new, PREVIOUS => "any-old-passphrase")
  end

  # --- refusal: the new key is absent -------------------------------------------

  test "refuses when the new key is absent" do
    assert_match(/NEW key\) is absent/, refusal(PREVIOUS => @old))
  end

  test "refuses when the new key is empty" do
    assert_match(/NEW key\) is absent/, refusal(KEY => "", PREVIOUS => @old))
  end

  # --- refusal: the new key is malformed ----------------------------------------

  test "refuses a new key that is one character short" do
    assert_match(/malformed: it is not 64 characters long/, refusal(KEY => @new[0, 63], PREVIOUS => @old))
  end

  test "refuses a new key carrying a trailing newline from a paste" do
    assert_match(/malformed: it has leading or trailing whitespace/, refusal(KEY => "#{@new}\n", PREVIOUS => @old))
  end

  test "refuses a new key that is not hexadecimal" do
    not_hex = "z#{@new[1..]}"
    assert_match(/malformed: it contains characters that are not hexadecimal/,
                 refusal(KEY => not_hex, PREVIOUS => @old))
  end

  test "refuses a passphrase as a new key" do
    assert_match(/malformed/, refusal(KEY => "correct horse battery staple", PREVIOUS => @old))
  end

  # --- refusal: the new key equals the old one ----------------------------------

  test "refuses a new key identical to the previous key" do
    assert_match(/equals/, refusal(KEY => @old, PREVIOUS => @old))
  end

  test "refuses a new key that differs from the previous only by case" do
    assert_match(/equals/, refusal(KEY => @old.upcase, PREVIOUS => @old))
  end

  test "refuses a new key that differs from the previous only by surrounding whitespace" do
    assert_match(/equals/, refusal(KEY => @old, PREVIOUS => " #{@old}\n"))
  end

  # --- refusal: the previous key is set but empty -------------------------------

  test "refuses a previous key that is SET but empty -- what an empty $OLD writes" do
    assert_match(/set but empty/, refusal(KEY => @new, PREVIOUS => ""))
  end

  test "refuses a previous key that is only whitespace" do
    assert_match(/set but empty/, refusal(KEY => @new, PREVIOUS => "  \n"))
  end
end
