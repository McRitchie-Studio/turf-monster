require "test_helper"
require "erb"
require "yaml"

# The test env must be able to point at a per-worktree database — and must never
# be pointed at a development one.
#
# THE BUG THIS GUARDS. `bin/agent-worktree` gives every desk its own test DB and
# writes it to .env.test.local as TEST_DATABASE_URL — and the comment it
# generates in that file states that config/database.yml's `test.url` reads the
# variable. This app's database.yml did not have that line. So the variable was
# set, believed, and ignored: every worktree's `bin/rails test` ran against the
# single shared `turf_monster_test`, and turf carries the most open worktrees in
# the ecosystem. One suite's fixtures then land inside another's run: counts
# drift, a seeded row turns up that nobody seeded, and both agents debug their
# own innocent change because the failure is in neither diff.
#
# The second half is quieter and worse. A worktree exports DATABASE_URL at its
# SEEDED DEVELOPMENT database, and Rails merges DATABASE_URL into whichever env
# is CURRENT — under RAILS_ENV=test, that is this block. Measured against this
# file before the fix: the test env resolved to `turf_monster_development`. An
# explicit `url:` outranks DATABASE_URL and takes that back; without one the test
# env is one stray export away from `db:test:prepare` PURGING a dev database.
#
# BOTH DIRECTIONS ARE ASSERTED, because a guard that only proved the override
# works would happily ship a database.yml that had stopped falling back — and the
# fallback is what CI and a plain primary checkout run on.
class TestDatabaseIsolationTest < ActiveSupport::TestCase
  CONFIG_PATH     = Rails.root.join("config/database.yml")
  SHARED_DATABASE = "turf_monster_test".freeze
  DEV_DATABASE    = "turf_monster_development".freeze

  # A worktree's two exports, as bin/agent-worktree actually writes them.
  ISOLATED_URL = "postgresql://localhost/turf_monster_test_some_worktree".freeze
  DEV_URL      = "postgresql://localhost/#{DEV_DATABASE}".freeze

  test "TEST_DATABASE_URL redirects the test env to an isolated database" do
    assert_equal "turf_monster_test_some_worktree",
                 resolved_test_database(test_url: ISOLATED_URL, database_url: nil),
                 "config/database.yml's test block must read TEST_DATABASE_URL, or every worktree " \
                 "shares one test database and the desks corrupt each other"
  end

  # THE MONEY CASE — the whole reason the line is `url:` and not something else.
  # A worktree has BOTH variables exported: DATABASE_URL at its seeded dev DB,
  # TEST_DATABASE_URL at its own test DB. Only an explicit `url:` outranks
  # DATABASE_URL. Before the fix this case resolved to turf_monster_development.
  test "TEST_DATABASE_URL outranks a DATABASE_URL pointed at the dev database" do
    assert_equal "turf_monster_test_some_worktree",
                 resolved_test_database(test_url: ISOLATED_URL, database_url: DEV_URL),
                 "DATABASE_URL (exported by every worktree at its SEEDED DEV DB) is overriding the " \
                 "test env — `db:test:prepare` would PURGE a development database"
  end

  # The property, stated as an invariant rather than as a list of spellings:
  # ONCE THE WORKTREE SEAM IS IN PLAY, nothing in the environment can drag the
  # test env off that desk's database. A future edit that satisfies the two cases
  # above by some other means still has to answer this one.
  test "with TEST_DATABASE_URL set, no DATABASE_URL can drag the test env elsewhere" do
    [nil, DEV_URL, "postgres://postgres:postgres@localhost:5432"].each do |database_url|
      resolved = resolved_test_database(test_url: ISOLATED_URL, database_url: database_url)

      assert_equal "turf_monster_test_some_worktree", resolved,
                   "with DATABASE_URL=#{database_url.inspect} the test env left the desk's own " \
                   "database — the isolation seam is not holding"
    end
  end

  # THE HOLE THIS LINE DOES NOT CLOSE. Written as a test so nobody reads the fix
  # as broader than it is.
  #
  # With TEST_DATABASE_URL ABSENT, the ERB renders empty, Rails treats `url:` as
  # absent, and DATABASE_URL merges into the test env exactly as before — so a
  # stray `DATABASE_URL=...development` export on a PRIMARY checkout still points
  # the test env at a development database. That cannot be fixed here: it is the
  # same mechanism CI depends on (see the CI contract test below), and the config
  # layer cannot tell CI's DATABASE_URL from an operator's stray one.
  #
  # What covers this case is Rails' protected-environments backstop, which
  # refuses when ar_internal_metadata names a different environment — the guard
  # that fired for this app on the day a sibling repo lost its database. If
  # someone ever closes this hole properly, this test SHOULD go red; update it
  # deliberately rather than deleting the note.
  test "an absent TEST_DATABASE_URL leaves DATABASE_URL in charge of the test env" do
    assert_equal DEV_DATABASE, resolved_test_database(test_url: nil, database_url: DEV_URL),
                 "documented residual: only the protected-environments backstop stands between a " \
                 "stray dev DATABASE_URL and db:test:prepare on a primary checkout"
  end

  test "the test env falls back to the shared database when the variable is absent" do
    # CI and a primary checkout never set TEST_DATABASE_URL. An override that
    # failed closed here would take the whole suite down everywhere but a desk.
    assert_equal SHARED_DATABASE, resolved_test_database(test_url: nil, database_url: nil)
    assert_equal SHARED_DATABASE, resolved_test_database(test_url: "", database_url: nil),
                 "an empty variable is the same as an absent one; dotenv writes empty values"
  end

  # THE CI CONTRACT, and the reason the ERB must stay bare.
  #
  # .github/workflows/ci.yml sets DATABASE_URL at the postgres service and never
  # sets TEST_DATABASE_URL. That works only because an EMPTY `url:` is treated by
  # Rails as absent, leaving the DATABASE_URL merge intact. Give the ERB a
  # default (`ENV.fetch("TEST_DATABASE_URL", "...")`) and this block becomes a
  # UrlConfig that outranks DATABASE_URL — CI would quietly stop talking to its
  # own postgres service and dial a local socket that is not there.
  test "DATABASE_URL still drives the test env when TEST_DATABASE_URL is absent" do
    # The literal DATABASE_URL from .github/workflows/ci.yml. The CREDENTIALS are
    # what is asserted, not the host: a hard-coded default in the ERB would still
    # land on `localhost`, so host alone passes straight through the mutation it
    # exists to catch. Only user/port prove the merge actually happened and that
    # CI is talking to its own postgres service.
    ci_url = "postgres://postgres:postgres@localhost:5432"
    config = resolved_test_config(test_url: nil, database_url: ci_url)

    assert_equal "turf_monster_test", config[:database]
    assert_equal "postgres", config[:username],
                 "CI reaches its postgres SERVICE through DATABASE_URL; if this stops merging, the " \
                 "suite dials a unix socket that does not exist on the runner"
    assert_equal 5432, config[:port]
  end

  # THE SEAM THIS FIX NEARLY BROKE. `bin/e2e-parallel` gives each shard its own
  # database by exporting DATABASE_URL — which the new `url:` now OUTRANKS. Inside
  # a worktree .env.test.local has already set TEST_DATABASE_URL at the DESK's
  # database, so a shard that exports DATABASE_URL alone resolves to the desk's DB
  # instead of its own. Measured before the script was updated: with
  # DATABASE_URL=postgres:///turf_monster_e2e_shard_3 the test env still resolved
  # to turf_monster_test_isolate_turf_test_database. The stakes are not a shared
  # database but a DROPPED one — each stack runs `db:drop db:create`.
  #
  # The ambient desk variable is what makes this test bite: the shard's exports are
  # applied ON TOP of it, exactly as they are in a real desk. Drop the
  # TEST_DATABASE_URL export from bin/e2e-parallel and the ambient value survives
  # and this goes red.
  test "every e2e-parallel stack resolves the test env to that stack's own database" do
    shard_database = "turf_monster_e2e_stack_7"
    ambient_desk   = "postgresql://localhost/turf_monster_test_a_sibling_desk"

    exports = File.readlines(Rails.root.join("bin/e2e-parallel"))
                  .grep(/^\s*export\s.*(?<!TEST_)DATABASE_URL=/)

    assert_predicate exports, :any?,
                     "bin/e2e-parallel no longer exports a per-stack database; this guard has gone blind"

    exports.each do |line|
      database_url      = line[/(?<!TEST_)DATABASE_URL="([^"]+)"/, 1]
      test_database_url = line[/TEST_DATABASE_URL="([^"]+)"/, 1]

      # `${db}` is the shell's per-stack name; stand a concrete one in its place.
      concrete = ->(value) { value&.gsub('${db}', shard_database) }

      resolved = resolved_test_database(
        # A stack that never sets TEST_DATABASE_URL inherits the desk's.
        test_url:     concrete.call(test_database_url) || ambient_desk,
        database_url: concrete.call(database_url)
      )

      assert_equal shard_database, resolved,
                   "an e2e-parallel stack resolved to #{resolved} instead of its own database — " \
                   "in a worktree the desk's ambient TEST_DATABASE_URL outranks this stack's " \
                   "DATABASE_URL, and every stack runs `db:drop db:create`. Offending line: #{line.strip}"
    end
  end

  # ASSERTS THE RUNNING PROCESS, not only the file. The two can disagree — the
  # file can be right while dotenv never loads .env.test.local — and it is the
  # running process that decides whose fixtures get written.
  test "this very suite is not running against the shared database" do
    running = ActiveRecord::Base.connection_db_config.database

    if ENV["TEST_DATABASE_URL"].present?
      refute_equal SHARED_DATABASE, running,
                   "TEST_DATABASE_URL is set but this suite is on the shared database — the override " \
                   "is being ignored and sibling worktrees are colliding"
    end

    refute_equal DEV_DATABASE, running,
                 "this suite is connected to the DEVELOPMENT database; fixtures are being written " \
                 "over real data right now"
  end

  # A CANARY, not the main event. Rails' own db:test:prepare / db:purge refuse to
  # touch a database whose ar_internal_metadata names a different environment —
  # that backstop is what saved this app on the day the sibling repo lost its DB,
  # and it is Rails-owned and Rails-tested. What this app can get wrong is
  # switching it OFF, so that is what is asserted here. The resolution tests
  # above are the ones that carry the property.
  test "the protected-environments backstop is not disabled in the test env" do
    assert_nil ENV["DISABLE_DATABASE_ENVIRONMENT_CHECK"],
               "DISABLE_DATABASE_ENVIRONMENT_CHECK removes Rails' last line of defence against " \
               "db:test:prepare purging a non-test database"
    assert_includes ActiveRecord::Base.protected_environments, "production"
  end

  private

    # What Rails itself would resolve `test` to, for a given pair of env vars.
    #
    # Renders the real file through ERB and hands the result to Rails' own
    # resolver rather than regex-matching the YAML: the question is which
    # database the app connects to, and only the resolver answers that. A
    # file-content guard would pass on a `url:` line Rails ignores.
    #
    # BOTH variables are controlled, never just TEST_DATABASE_URL. DATABASE_URL
    # is ambient in exactly the places this suite runs — a worktree that sourced
    # .env.agent-stack, and bin/release's gate workspaces, both export it — and
    # Rails merges it into the CURRENT env, which is `test` here. Leaving it to
    # the ambient value would make the fallback cases resolve to whatever the
    # operator happened to export and fail for a reason unrelated to the property.
    def resolved_test_config(test_url:, database_url:)
      with_env("TEST_DATABASE_URL" => test_url, "DATABASE_URL" => database_url) do
        yaml = YAML.safe_load(ERB.new(File.read(CONFIG_PATH)).result, aliases: true)
        ActiveRecord::DatabaseConfigurations.new(yaml)
                                            .configs_for(env_name: "test", name: "primary")
                                            .configuration_hash
      end
    end

    def resolved_test_database(test_url:, database_url:)
      resolved_test_config(test_url: test_url, database_url: database_url)[:database]
    end

    def with_env(values)
      original = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
