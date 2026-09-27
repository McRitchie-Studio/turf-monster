# frozen_string_literal: true

require "test_helper"

# [docs-guard] docs/qa-signing-key-rotation.md, the ceremony runbook Mr.
# McRitchie runs by hand (task fix-qa-signer-ceremony-tooling).
#
# A runbook is executed, not read, so its defects are operational: a secret
# that lands on a command line is in `ps` and shell history; a step that leaves
# SOLANA_MULTISIG_SIGNERS stale keeps QA offering an evicted key as cosigner; a
# rollback that "restores" a key the chain no longer seats leaves QA dead while
# claiming recovery. Each assertion below pins one of those, and each was found
# in the runbook as it merged with separate-qa-solana-signing-key.
class QaSigningKeyRunbookTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/qa-signing-key-rotation.md")

  def doc = @doc ||= DOC.read

  # The body of "## Step N — …" up to the next "## ".
  def step(number)
    doc[/^## Step #{number} —.*?(?=^## )/m] or flunk "runbook has no Step #{number}"
  end

  def code_blocks = doc.scan(/^```[a-z]*\n(.*?)^```/m).flatten

  # ── NO SECRET ON A COMMAND LINE ─────────────────────────────────────────
  #
  # argv is visible to every process on the machine (`ps`) and is written to
  # shell history. A secret may travel over a pipe or a 0600 file, never argv.

  test "no command substitutes a secret into an argument" do
    code = code_blocks.join("\n")
    refute_match(/\$\(\s*op read/, code, "$(op read …) expands the secret into argv")
    refute_match(/=\$\(\s*op /, code)
    refute_match(/concealed\]=\$/, code, "an op assignment statement puts the secret on argv")
    refute_match(/\[concealed\]=/, code)
    refute_match(/heroku config:set\s+SOLANA_ADMIN_KEY/, code, "heroku config:set takes its values on argv")
    refute_match(/auth:token\)/, code, "the Heroku token must not be substituted into argv either")
  end

  test "the 1Password item is created from a template on stdin" do
    assert_match(/\|\s*op item create\b[^\n]*(?:\\\n[^\n]*)*\s-\s*\\?\n/, step(3),
                 "op item create reads the concealed field from a JSON template on stdin (`-`)")
  end

  test "QA's key is set through the Platform API with the body on stdin and the output discarded" do
    eight = step(8)
    assert_match(/--data-binary @-/, eight, "the config body must come from stdin")
    assert_match(/-H @"\$h"/, eight, "the Authorization header must come from a file, not argv")
    assert_match(%r{-o /dev/null}, eight, "the API answers with every config var, secrets included")
    assert_match(/umask 077/, eight)
    assert_match(/rm -P "\$h"/, eight)
  end

  # ── THE SIGNER LIST MOVES WITH THE KEY ──────────────────────────────────

  test "step 8 sets SOLANA_MULTISIG_SIGNERS for every option, from the value the dry run prints" do
    var = Solana::QaSignerRotation::MULTISIG_SIGNERS_VAR
    eight = step(8)
    assert_match(/#{var}/, eight)
    assert_match(/"#{var}"\s*=>/, eight, "the one PATCH must carry the signer list beside the key")
    assert_match(/every option/i, eight)
    assert_match(/after .*--show/im, eight, "the list is set only after the chain read-back")
    assert_match(/#{var}=/, step(5), "step 5 must tell the operator the dry run prints the value")
  end

  # ── ROLLBACK, OPTION BY OPTION ──────────────────────────────────────────

  test "rollback is stated for each option, and option B's names the reverse rotation" do
    rollback = doc[/^### Rollback.*?(?=^## )/m] or flunk "runbook has no Rollback section"
    %w[A B C].each { |opt| assert_match(/\*\*Option #{opt}\b/, rollback, "no rollback text for option #{opt}") }

    b = rollback[/\*\*Option B.*?(?=\*\*Option C)/m]
    assert_match(/no longer a devnet signer/, b)
    assert_match(/reverse rotation/i, b)
    assert_match(/8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd/, b, "the reverse rotation must name the slot to restore")
    refute_match(/works again at once/, b)
  end

  # ── THE DRY RUN'S v0.25 RULE IS THE RUNBOOK'S ───────────────────────────

  test "every v0.25 dry-run COMMAND names exactly two cosigners" do
    commands = step(5).scan(/^```[a-z]*\n(.*?)^```/m).flatten.join("\n")
    lists = commands.scan(/--cosigners\s+(\S+)/).flatten
    assert_operator lists.length, :>=, 2, "step 5 should carry a dry run per v0.25 option"
    lists.each do |list|
      assert_equal 2, list.split(",").length, "v0.25 takes exactly two cosigners: #{list}"
    end
  end
end
