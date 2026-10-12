# frozen_string_literal: true

require "test_helper"

# [docs-guard] docs/SOLANA.md's "Evicting a signer" section names the two builds
# `Solana::Vault#build_update_signers` picks between, and each name is checked
# against what that method actually calls.
#
# THE DEFECT THIS EXISTS FOR. The operator-leads bullet named
# `build_partial_unsigned`, a real method in vault.rb, so a reader who grepped
# for it found it and believed the doc. `build_update_signers` never calls it:
# the operator-led branch is `build_lead_paid_unsigned`, where the LEAD pays the
# fee and every signature comes from Phantom. An existence check could not catch
# that; only reading the method the doc describes can.
#
# CONTROL: put `build_partial_unsigned` back on the operator-leads line and the
# second test fails, naming both builders.
class UpdateSignersBuilderDocTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/SOLANA.md")

  # The `build_*` calls in the body of Vault#build_update_signers, read from its
  # source so the doc is held to the code rather than to a copy of it.
  def builders_called
    file, line = Solana::Vault.instance_method(:build_update_signers).source_location
    lines = File.readlines(file)[(line - 1)..]
    indent = lines.first[/\A\s*/]
    body = lines.take_while.with_index { |l, i| i.zero? || !l.start_with?("#{indent}end") }
    body.drop(1).join.scan(/\b(build_[a-z_]+)\(/).flatten.uniq
  end

  # The builder the doc names on the "**<who> leads** → `build_…`" bullet.
  def doc_builder(who)
    line = File.readlines(DOC).find { |l| l.include?("**#{who} leads** →") }
    assert line, "docs/SOLANA.md has no \"**#{who} leads** →\" bullet"
    line[/`(build_[a-z_]+)`/, 1]
  end

  test "the method the section names is the update_signers builder" do
    assert_includes File.read(DOC), "`Vault#build_update_signers` takes a `lead_signer:`"
    assert Solana::Vault.method_defined?(:build_update_signers)
  end

  test "each lead's bullet names a builder build_update_signers actually calls" do
    called = builders_called
    assert_equal %w[build_lead_paid_unsigned build_partial_signed], called.sort,
                 "build_update_signers' builds changed; update docs/SOLANA.md \"Evicting a signer\" too"

    assert_equal "build_partial_signed", doc_builder("server")
    assert_equal "build_lead_paid_unsigned", doc_builder("operator"),
                 "the operator-leads bullet names #{doc_builder('operator')}; the code calls #{called.join(' and ')}"
  end
end
