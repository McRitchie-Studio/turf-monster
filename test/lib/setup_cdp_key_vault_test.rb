# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "base64"
require "shellwords"

# The 1Password vault `bin/setup-cdp-key` reads from.
#
# WHY THIS FILE EXISTS (2026-08-29, measured — not hypothesised). The vault was
# renamed `agents` → `agents-studio` on 2026-08-28. `bin/setup-cdp-key` carried
# the old name as a bare string literal in TWO places (a header comment and
# OP_ITEM), so its default no-arg mode — the recommended path, the one the
# header calls "recommended" — died on every machine at once with
#
#   [ERROR] could not read secret 'op://agents/Coinbase Developer Platform/API
#   key ID': could not get item agents/Coinbase Developer Platform: "agents"
#   isn't a vault in this account.
#
# reproduced against the live service account the same day. The fix is NOT a
# second literal: mcritchie-studio's bin/lib/op_vaults.rb resolves the vault as
# an OVERRIDE WITH A DEFAULT (`MCR_OP_VAULT_AGENT`, default `agents-studio`)
# precisely so the next rename is an env var and not another fleet-wide break.
# A hardcoded `agents-studio` would pass a naive "is the new name present?"
# check and re-arm the same bug.
#
# THE TIERS, and why the unit half is not enough on its own. The unit tests read
# the SOURCE — they can prove the literal is gone and the override form is
# present, but they cannot prove the shell EXPANDS it to a reference `op` will
# accept: `${MCR_OP_VAULT_AGENT:-agents-studio}` inside single quotes, or a
# stray `$`, reads correctly and resolves to garbage. The integration test runs
# the real script across its `op` boundary with a stub that emulates the service
# account's actual grants (one visible vault; anything else fails with op's own
# wording), so the assertion is on the reference the script REALLY asks for.
class SetupCdpKeyVaultTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/setup-cdp-key")

  # The default the fix must carry, and the override that makes it a default
  # rather than a second hardcoding. Kept as literals HERE on purpose: this file
  # is the contract, so a rename has to be made deliberately in one place.
  AGENT_VAULT = "agents-studio"
  VAULT_OVERRIDE_ENV = "MCR_OP_VAULT_AGENT"
  ITEM = "Coinbase Developer Platform"

  # A CDP Ed25519 secret is base64 of exactly 64 bytes — the script aborts on
  # anything else, so the stub has to hand back a real one or the run dies for
  # the wrong reason and the test would pass on a false negative.
  STUB_KEY_ID = "11111111-2222-3333-4444-555555555555"
  STUB_SECRET = Base64.strict_encode64("k" * 64)

  # ---------------------------------------------------------------- unit ----

  def test_the_script_names_no_hardcoded_vault_in_an_op_reference
    offenders = source.each_line.with_index(1).select do |line, _n|
      line.match?(%r{op://(?!\$\{#{Regexp.escape(VAULT_OVERRIDE_ENV)})[A-Za-z0-9._-]+/})
    end

    assert_empty offenders.map { |line, n| "#{n}: #{line.strip}" },
                 "every op:// reference in bin/setup-cdp-key must resolve its vault through " \
                 "${#{VAULT_OVERRIDE_ENV}:-#{AGENT_VAULT}}. A literal vault name — the OLD one or " \
                 "the new one — is the defect: `agents` broke the whole fleet on 2026-08-28, and " \
                 "a hardcoded `#{AGENT_VAULT}` breaks it again on the next rename. See " \
                 "mcritchie-studio bin/lib/op_vaults.rb, the single source for lane => vault."
  end

  # ANCHORED ON THE ASSIGNMENT, not on the file. A whole-source `assert_includes`
  # is satisfied by the HEADER COMMENT that documents the form — measured: it
  # stayed green while OP_ITEM was mutated back to a hardcoded `agents-studio`,
  # which is the exact "second literal" mistake this task exists to prevent. The
  # executable line is the only one that decides anything, so assert on it.
  def test_the_override_carries_the_agent_vault_as_its_default
    assignment = source.each_line.find { |line| line.start_with?("OP_ITEM=") }

    assert assignment, "bin/setup-cdp-key must still build its op:// reference in one OP_ITEM assignment"
    assert_includes assignment, "${#{VAULT_OVERRIDE_ENV}:-#{AGENT_VAULT}}",
                    "the vault must be an override WITH A DEFAULT, so an unset environment still " \
                    "resolves to the agent vault instead of an empty vault name. Found: #{assignment.strip}"
  end

  def test_the_old_vault_name_is_gone_from_prose_too
    stale = source.each_line.with_index(1).select { |line, _n| line.match?(%r{op://agents/}) }

    assert_empty stale.map { |line, n| "#{n}: #{line.strip}" },
                 "the header comment is the first thing an operator reads when this script fails; " \
                 "leaving `op://agents/` there sends them to a vault that no longer exists"
  end

  # --------------------------------------------------------- integration ----

  # The whole point: run the REAL script against a stubbed `op` that behaves the
  # way the live service account behaves — exactly one visible vault — and read
  # back the reference it asked for.
  def test_the_no_args_mode_reads_the_agent_vault_and_installs_the_key
    result = run_script(visible_vault: AGENT_VAULT)

    assert_equal 0, result[:status],
                 "no-args mode must succeed against the agent vault. stdout/stderr:\n#{result[:output]}"
    assert_equal ["op://#{AGENT_VAULT}/#{ITEM}/API key ID", "op://#{AGENT_VAULT}/#{ITEM}/Secret"],
                 result[:refs],
                 "the script must ask 1Password for the item in the agent vault"
    assert_includes result[:env_file], "CDP_API_KEY_ID=#{STUB_KEY_ID}",
                    "a successful read must actually install the key id into .env"
    assert_includes result[:env_file], "CDP_API_KEY_SECRET=\"#{STUB_SECRET}\""
  end

  # THE REGRESSION ITSELF. Point the stub at the old vault and the run must
  # fail — which is what proves the previous test passed for the right reason
  # and not because the stub answers anything it is asked.
  def test_the_run_fails_when_the_agent_vault_is_not_visible
    result = run_script(visible_vault: "agents")

    refute_equal 0, result[:status],
                 "if the stub served a vault the script never named, the success case above " \
                 "would prove nothing. Output:\n#{result[:output]}"
    assert_empty result[:env_file],
                 "a failed 1Password read must not leave a half-written .env behind"
  end

  def test_the_override_redirects_the_read_without_editing_the_script
    result = run_script(visible_vault: "agents-elsewhere",
                        env: { VAULT_OVERRIDE_ENV => "agents-elsewhere" })

    assert_equal 0, result[:status],
                 "a machine whose vaults are named differently must override rather than fork " \
                 "the script. Output:\n#{result[:output]}"
    assert_equal "op://agents-elsewhere/#{ITEM}/API key ID", result[:refs].first
  end

  private

  def source
    @source ||= File.read(SCRIPT)
  end

  # Runs bin/setup-cdp-key with NO arguments in a throwaway checkout-shaped
  # directory, with a stub `op` first on PATH.
  #
  # The copy is not cosmetic: the script does `cd "$(dirname "$0")/.." ` and
  # writes `.env` there, so running it in place would overwrite the developer's
  # real .env with fixture values.
  def run_script(visible_vault:, env: {})
    Dir.mktmpdir("setup-cdp-key") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      script = File.join(dir, "bin", "setup-cdp-key")
      FileUtils.cp(SCRIPT, script)
      FileUtils.chmod(0o755, script)

      stub_dir = File.join(dir, "stub")
      log = File.join(dir, "op-refs.log")
      write_op_stub(stub_dir, log: log, visible_vault: visible_vault)

      output = IO.popen(
        {
          "PATH" => "#{stub_dir}:#{ENV['PATH']}",
          "OP_STUB_LOG" => log,
          "OP_STUB_VAULT" => visible_vault,
          "OP_STUB_KEY_ID" => STUB_KEY_ID,
          "OP_STUB_SECRET" => STUB_SECRET,
          VAULT_OVERRIDE_ENV => nil
        }.merge(env),
        [shell, script],
        err: [:child, :out],
        &:read
      )

      {
        status: $?.exitstatus,
        output: output.to_s,
        refs: File.exist?(log) ? File.read(log).split("\n") : [],
        env_file: File.exist?(File.join(dir, ".env")) ? File.read(File.join(dir, ".env")) : ""
      }
    end
  end

  # bin/setup-cdp-key is `#!/bin/zsh`. macOS always has it; a Linux CI runner may
  # not, so fall back to bash rather than skip — a tier that quietly stops
  # running is worth less than nothing, because the board still credits it.
  # Safe here because the line under test, `OP_ITEM="op://${VAR:-default}/..."`,
  # is POSIX parameter expansion with identical semantics in both shells; the
  # unit test above pins the form so a future zsh-only rewrite is caught in the
  # tier that reads source rather than silently diverging here.
  def shell
    @shell ||= %w[/bin/zsh /usr/bin/zsh /bin/bash].find { |s| File.executable?(s) } ||
               raise("no zsh or bash available to run #{SCRIPT}")
  end

  # Emulates `op` as the agent service account sees the world: ONE readable
  # vault. A stub that answered every vault would certify the broken script
  # green — the failure mode this repo has already paid for.
  def write_op_stub(dir, log:, visible_vault:)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "op")
    File.write(path, <<~SH)
      #!/bin/sh
      case "$1" in
        whoami) echo "User Type: SERVICE_ACCOUNT"; exit 0 ;;
        read)
          ref="$2"
          printf '%s\\n' "$ref" >> "$OP_STUB_LOG"
          vault=$(printf '%s' "$ref" | sed -e 's|^op://||' -e 's|/.*$||')
          if [ "$vault" != "$OP_STUB_VAULT" ]; then
            echo "[ERROR] could not read secret '$ref': \\"$vault\\" isn't a vault in this account." >&2
            exit 1
          fi
          case "$ref" in
            *"/API key ID") printf '%s\\n' "$OP_STUB_KEY_ID" ;;
            *"/Secret")     printf '%s\\n' "$OP_STUB_SECRET" ;;
            *) echo "[ERROR] no such field: $ref" >&2; exit 1 ;;
          esac
          ;;
        *) echo "[ERROR] unsupported op subcommand: $1" >&2; exit 1 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
    log
  end
end
