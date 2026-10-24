# frozen_string_literal: true

# GUARD (secrets-never-on-argv-or-desk-env, 2026-10-24): a secret never appears on a
# command line.
#
# WHY. `ps` shows every process's arguments to every local process, and an agent's
# `pgrep -fl` or `ps` lands them in a transcript. The hub's rotation SOP told the
# operator to run `heroku config:set <VAR>=$NEW` and `op item edit … [concealed]=$NEW`
# until this guard's twin (mcritchie-studio test/docs/secrets_on_argv_guard_test.rb)
# shipped with the rewrite. This scans the places an agent copies commands from in
# this repo and fails on a new argv form. The fixes: stdin (`printf '%s' "$V" | cmd`,
# `op item create -` with a JSON template), a Platform API PATCH with the body on
# stdin and the token in a header file (docs/qa-signing-key-rotation.md step 8, or
# mcritchie-studio bin/heroku-secret-set), and a curl header from a file or
# `-H @<(printf 'Authorization: Bearer %s\n' "$TOKEN")`.
#
# WHAT COUNTS (one line at a time, backslash continuations joined): a `config:set`
# of a secret-looking name or value; an `op item edit|create` assignment of a
# concealed field or secret variable; `--token|--api-key|--password|--secret $VAR`;
# an `Authorization:` (or any secret/token/key/auth-named) header taking a variable;
# a curl `-d` carrying a secret variable; and `NAME=$(op read …) cmd`. The patterns
# are the hub twin's; keep the two in step.
#
# THE CONTROL. Every pattern fires on a known offender and stays quiet on its
# argv-free rewrite, so a blind pattern fails here instead of passing the tree.
#
# Run directly:  ruby -Itest test/lib/secrets_on_argv_guard_test.rb
require "minitest/autorun"

class SecretsOnArgvGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # docs/runbooks, docs/workflows and the operator runbooks at docs/ top level are
  # where this repo keeps the commands an agent copies; docs/agents is named for
  # parity with the hub (none exists here yet).
  SCANNED = %w[bin lib/tasks docs .github/workflows].freeze
  # The public agent-API reference. Its curl examples are a CLIENT's own key on the
  # client's machine, and they mirror the served guide
  # (app/views/agents/guide_source.text.erb), which this guard does not scan; a
  # change to one belongs with the other, in a product task.
  EXCLUDED = %w[docs/AGENT_API.md].freeze

  SECRET_NAME = /KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE|\A(?:NEW|OLD|T)\z/i
  PUBLIC_NAME = /PUB_?KEY|PUBLIC_?KEY|KEY_ID\z|_ID\z|_URL\z|_PATH\z|_FILE\z|_NAME\z/i
  VAR_REF = /\$\{?([A-Za-z_][A-Za-z0-9_]*)|\$\{\{\s*secrets\.([A-Za-z0-9_]+)/
  SECRET_SUBST = /\$\((?:op read|op item get|cat |pbpaste)/

  def self.secret_name?(name)
    !name.nil? && name.match?(SECRET_NAME) && !name.match?(PUBLIC_NAME)
  end

  def self.secret_ref?(value)
    return true if value.match?(SECRET_SUBST) || value.match?(/\$\{\{\s*secrets\./)

    value.scan(VAR_REF).flatten.compact.any? { |name| secret_name?(name) }
  end

  def self.offences(line)
    found = []
    if line.include?("config:set")
      line.scan(/(<[A-Za-z_ ]+>|\b[A-Z][A-Z0-9_]*)=("[^"]*"|'[^']*'|\$\([^)]*\)|\S*)/).each do |name, value|
        found << "config:set #{name}" if secret_name?(name) || secret_ref?(value)
      end
    end
    if line.match?(/\bop item (?:edit|create)\b/)
      line.scan(/\]=("[^"]*"|\S*)/).flatten.each { |value| found << "op item assignment" if secret_ref?(value) }
      found << "op item concealed assignment" if line.match?(/\[(?:concealed|password)\]=/)
    end
    flag = /--(?:token|api-key|api_key|password|secret|auth-token|access-token)[ =]["']?(\$\{?[A-Za-z_]|\$\{\{|\$\()/
    found << "secret flag" if line.match?(flag)
    found << "auth header" if line.match?(/Authorization: (?:Bearer|token|Basic) \$(?:\{?[A-Za-z_]|\{\{|\()/)
    line.scan(/-H\s+["']([A-Za-z-]*(?:secret|token|key|auth)[A-Za-z-]*):\s*([^"']*)["']/i).each do |_header, value|
      found << "secret header" if value.match?(/\$(?:\{?[A-Za-z_]|\{\{|\()/)
    end
    line.scan(/(?:\s-d|--data(?:-binary|-raw|-urlencode)?)[ =](?:"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+))/).each do |parts|
      found << "secret in request data" if secret_ref?(parts.compact.first.to_s)
    end
    found << "op read prefix" if line.match?(/(?:\A|[\s;&|(])[A-Z][A-Z0-9_]*=["']?\$\((?:op read|op item get)[^)]*\)["']?[ \t]+[a-z.\/]/)
    found.uniq
  end

  def scanned_files
    Dir.chdir(ROOT) { `git ls-files -- #{SCANNED.join(" ")}`.split("\n").select { |f| File.file?(f) } - EXCLUDED }
  end

  def offenders_in(text, label)
    hits = []
    lineno = 0
    buffer = +""
    start = nil
    text.each_line do |raw|
      lineno += 1
      start ||= lineno
      line = raw.chomp
      if line.end_with?("\\")
        buffer << line.chomp("\\") << " "
        next
      end
      buffer << line
      found = self.class.offences(buffer)
      hits << "#{label}:#{start}: #{found.join(', ')}" unless found.empty?
      buffer = +""
      start = nil
    end
    hits
  end

  def test_no_command_puts_a_secret_on_argv
    files = scanned_files

    assert_operator files.length, :>=, 40, "only #{files.length} files scanned; the file list has gone blind"
    assert_includes files, "bin/tm", "bin/tm is not in the scan"

    hits = files.flat_map do |file|
      text = File.read(File.join(ROOT, file), encoding: "UTF-8")
      text.valid_encoding? ? offenders_in(text, file) : []
    end

    assert hits.empty?, <<~MSG
      These lines put a secret on a command line, where `ps` shows it to every local
      process and an agent's process listing lands it in a transcript:

      #{hits.join("\n")}

      Pass it by stdin instead: `printf '%s' "$V" | cmd`, a Platform API PATCH with the
      body on stdin (docs/qa-signing-key-rotation.md step 8, or mcritchie-studio
      bin/heroku-secret-set), or a curl header from
      `-H @<(printf 'Authorization: Bearer %s\\n' "$TOKEN")`.
    MSG
  end

  OFFENDERS = [
    'heroku config:set "<VAR>=$NEW" --app "$app"',
    "heroku config:set CDP_API_KEY_SECRET=<secret> -a turf-monster-mainnet",
    'heroku config:set SOLANA_ADMIN_KEY="$(op read op://v/i/private-key)" -a turf-monster-qa',
    'op item edit item "private-key[concealed]=$KEY"',
    'stripe listen --api-key "$STRIPE_SECRET_KEY" --forward-to localhost:3100/webhooks/stripe',
    "deploy --token ${{ secrets.HEROKU_API_KEY }}",
    'curl -H "Authorization: Bearer $TURF_MONSTER_KEY" https://turfmonster.media/api/v1/me',
    'curl -H "X-Api-Key: $CDP_API_KEY_SECRET" https://api.example',
    'curl -X POST https://x/auth -d "{\"secret\": \"$AGENT_API_SECRET\"}"',
    "SOLANA_ADMIN_KEY=$(op read 'op://v/i/f') bin/rails solana:init_vault"
  ].freeze

  QUIET = [
    'heroku config:set EXPECTED_IDL_HASH="$(widened_set)" --app "$HEROKU_APP"',
    'heroku config:set SOLANA_MULTISIG_SIGNERS="8K81,$QA_PUBKEY" --app turf-monster-qa',
    "heroku config:set ENABLE_CDP_RAMP=true -a turf-monster-mainnet",
    'export STRIPE_API_KEY="$key"',
    "op item create --vault v - \"wallet-address[text]=$QA_PUBKEY\"",
    "curl -sS -H @\"$h\" --data-binary @- https://api.heroku.com/apps/turf-monster-qa/config-vars",
    "curl -H @<(printf 'Authorization: Bearer %s\\n' \"$TURF_MONSTER_KEY\") https://turfmonster.media/api/v1/me",
    'request["Authorization"] = "Bearer #{token}"'
  ].freeze

  # The exclusion holds only while its reason does: the file is the client reference
  # and the served guide carries the same example.
  def test_the_excluded_reference_still_mirrors_the_served_guide
    example = 'curl -H "Authorization: Bearer $TURF_MONSTER_KEY"'

    assert_includes File.read(File.join(ROOT, "docs/AGENT_API.md")), example
    assert_includes File.read(File.join(ROOT, "app/views/agents/guide_source.text.erb")), example
  end

  def test_control_every_pattern_fires_on_an_offender_and_not_on_its_rewrite
    OFFENDERS.each { |line| refute_empty self.class.offences(line), "the guard is blind to: #{line}" }
    QUIET.each { |line| assert_empty self.class.offences(line), "the guard flags an argv-free line: #{line}" }
  end

  def test_control_a_continuation_joined_offender_is_named_by_its_first_line
    hits = offenders_in("echo start\nheroku config:set \\\n  \"<VAR>=$NEW\" --app x\n", "fixture.md")

    assert_equal 1, hits.length, hits.inspect
    assert hits.first.start_with?("fixture.md:2: config:set"), hits.inspect
  end
end
