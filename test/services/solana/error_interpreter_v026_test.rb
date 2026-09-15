require "test_helper"

# The v0.26 error range (6045-6066). Every code the program can emit should
# reach a person as a sentence, not as 0x17ac.
#
# THE ONE THAT MATTERS MOST is 6060. The username registry moved uniqueness from
# a Rails convention to an on-chain fact, so a name can now be taken between the
# form render and the submit — an ordinary thing a person can fix, which must not
# surface as a hex code or be logged as a fault.
class Solana::ErrorInterpreterV026Test < ActiveSupport::TestCase
  V026_IDL = JSON.parse(File.read(Rails.root.join("config", "turf_vault.v026.idl.json"))).freeze

  def interpret(msg) = Solana::ErrorInterpreter.interpret(msg)

  # Codes the program declares as reserved placeholders. They carry the message
  # "Reserved — do not emit", so mapping them would be mapping a thing that
  # cannot happen.
  RESERVED = (6057..6059).to_a.freeze

  test "every v0.26 error code is interpreted, by number and by hex" do
    unmapped = []

    V026_IDL.fetch("errors").each do |err|
      code = err.fetch("code")
      next if code < 6045 || RESERVED.include?(code)

      [code.to_s, format("0x%x", code), err.fetch("name")].each do |form|
        raw = "failed to send transaction: custom program error: #{form}"
        result = interpret(raw)
        unmapped << "#{code} via #{form}" if result[:message] == raw
      end
    end

    assert_empty unmapped,
                 "these v0.26 errors pass through raw, so a person would see a hex code: #{unmapped.join(', ')}"
  end

  test "a taken username reads as a person's problem, not a fault" do
    result = interpret("custom program error: 0x17ac")

    assert_match(/already taken/i, result[:message])
    refute result[:log], "someone picking a taken name is not a fault to alarm on"
    refute result[:blocker], "it must not block the form — they can just pick another"
  end

  test "the half-upgrade signature errors name which half is missing" do
    insufficient = interpret("custom program error: 0x179e")
    assert_match(/vault signatures/i, insufficient[:message])
    assert insufficient[:log], "a short signature set during an upgrade window must be loud"

    did_not_sign = interpret("custom program error: 0x179f")
    assert_match(/did not sign/i, did_not_sign[:message])
    assert did_not_sign[:log]
  end

  test "a moved mint window is retryable rather than terminal" do
    result = interpret("custom program error: 0x17a5")
    assert_match(/try again/i, result[:message])
    assert result[:toast]
  end

  test "the invite-quest refusal states the business rule" do
    result = interpret("custom program error: 0x17a7")
    assert_match(/entered a contest/i, result[:message])
    refute result[:log], "a friend who has not entered yet is expected, not an error to alarm on"
  end

  # CONTROL. The v0.25 codes this file does not touch must still interpret
  # exactly as before, or these new patterns are swallowing their neighbours —
  # the failure mode a block of regexes invites. 0x1772 and 0x1784 sit adjacent
  # to the ranges added above.
  test "the pre-existing codes are unchanged by the new patterns" do
    assert_match(/balance/i, interpret("custom program error: 0x1772")[:message])
    assert_match(/reserved/i, interpret("custom program error: 0x1784")[:message])
    assert_match(/no longer open/i, interpret("custom program error: 0x1773")[:message])
    assert_match(/full/i, interpret("custom program error: 0x1774")[:message])
  end

  # CONTROL. An unmapped string must still pass through untouched, or the
  # completeness test above would be satisfied by a catch-all that maps
  # everything and proves nothing.
  test "an unrelated error still passes through raw" do
    raw = "custom program error: 0x9999"
    assert_equal raw, interpret(raw)[:message]
  end
end
