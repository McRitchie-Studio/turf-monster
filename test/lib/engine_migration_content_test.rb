# frozen_string_literal: true

require "test_helper"
require "digest"
require "ripper"
require "tmpdir"
require "fileutils"

# [unit] The CONTENT half of the engine-migration contract.
#
# `test/lib/engine_pin_contract_test.rb` asks which engine migrations are
# installed here, BY NAME. That catches a migration this app never copied. It is
# blind to a migration whose BODY changed in the gem, because the name never
# moved — and engine migrations are install-COPIED
# (`bin/rails studio_engine:install:migrations`), never referenced. Every
# consumer holds a FORK, `bin/rails db:migrate` runs the file in THIS repo, and a
# gem bump delivers nothing. So a rewritten migration leaves every unsynced
# consumer green forever.
#
# THAT IS NOT HYPOTHETICAL. On 2026-08-13 studio-engine rewrote
# AddStandardUserProfileColumns so its `down` REFUSES instead of dropping
# host-owned columns (studio-engine commit 4c18516). Three consumers had to
# hand-sync their copies in three separate PRs. Had one been forgotten, no gate
# anywhere would have gone red, and that app would have kept the destructive
# rollback the engine had just removed — the fix silently un-fixed, in
# production. `test/lib/standard_profile_rollback_guard_test.rb` pins the
# BEHAVIOUR of that one migration; the engine ships nine, and this file asks the
# general question about all of them.
#
# WHAT IS COMPARED, AND WHY IT IS NOT BYTES.
#
# The digest is over the migration's CODE TOKENS — Ripper's lexer with
# whitespace and comments dropped — not over its bytes. Two measured reasons:
#
#   1. The installer PREPENDS a provenance line
#      (`# This migration comes from studio_engine (originally <ts>)`), so an
#      installed copy is never byte-equal to its source. That line is also the
#      only record of WHICH gem migration this file is a copy of — the installer
#      renumbers the filename to the install time — so it is read for identity
#      and then excluded from the digest.
#   2. Consumers run rubocop over db/migrate and it rewrites the copies in
#      place. MEASURED 2026-08-14 on mcritchie-industries'
#      `create_studio_enumerals` copy: it differs from studio-engine 0.47.1's
#      file only as `[ :category, :key ]` against `[:category, :key]`. A byte
#      gate reds there on the day rubocop runs, in an app that has drifted in no
#      way that matters — and a guard that reds on formatting is a guard
#      somebody switches off.
#
# Dropping COMMENTS is the deliberate half of that choice. A comment-only
# divergence cannot change what a migration does, and the property defended here
# is behavioural. The 2026-08-13 rewrite moved both halves — `def change` became
# `def up` plus a refusing `def down` — so the code alone is enough to bite,
# which the mutation test below PROVES rather than assumes.
#
# WHAT TO DO WHEN THIS FAILS, because the obvious move does not work.
# `ActiveRecord::Migration.copy` SKIPS any migration whose name is already
# installed, so re-running `studio_engine:install:migrations` will not refresh a
# drifted copy. And for a migration that has already RUN, deleting the file and
# reinstalling is worse than useless: the copy comes back under a NEW timestamp,
# arrives PENDING, while the old version stays stamped in schema_migrations.
# Hand-sync the body into the EXISTING file, keeping its filename and timestamp.
# That is exactly what the three consumer PRs did on 2026-08-13.
class EngineMigrationContentTest < ActiveSupport::TestCase
  # Divergences this app has LOOKED AT and accepted, as bare migration name =>
  # the reason it stands. An entry is a decision, not a mute button: the last
  # test in this file fails when an entry stops describing anything real, so the
  # list cannot rot into a blanket exemption.
  #
  # Re-syncing an already-run migration is normally the WRONG move — you do not
  # rewrite history — and this is where that judgement gets recorded. The
  # 2026-08-13 rewrite was re-synced only because the change was confined to the
  # `down` path, which has never executed anywhere.
  ACKNOWLEDGED_DRIFT = {}.freeze

  # The installed filename the fixture tests below build in tmp.
  STUDIO_FIXTURE_COPY = "20260505000000_create_studio_enumerals.studio_engine.rb"

  # Compares this app's installed engine migrations against the gem's originals.
  #
  # Takes its directories as arguments rather than reading Rails.root directly,
  # which is what lets the mutation tests below point it at a PERTURBED copy of
  # this app's real db/migrate and watch it go red.
  class Copies
    # The installer's provenance line, always the first line of a copied file.
    # Its first capture is the SCOPE — which engine the copy came from.
    PROVENANCE = /\A#[ \t]*This migration comes from ([a-z_]+) \(originally (\d+)\)[ \t]*\r?\n/

    # The scopes that mean "studio-engine". `ActiveRecord::Migration.copy` stamps
    # a copy with the railtie name, so ASK the engine for today's spelling rather
    # than hardcoding it — renaming the engine would otherwise walk every future
    # copy quietly out of this guard's sight. `studio` is the historical
    # spelling, still installed in mcritchie-industries.
    SCOPES = ([ Studio::Engine.railtie_name ] + %w[studio studio_engine]).uniq.freeze
    SCOPED_COPY = /\.(#{SCOPES.map { |scope| Regexp.escape(scope) }.join("|")})\.rb\z/

    # Lexer tokens that carry no behaviour: layout, and comments.
    IGNORED_TOKENS = %i[on_sp on_nl on_ignored_nl on_comment on_embdoc_beg on_embdoc on_embdoc_end].freeze

    Finding = Struct.new(:name, :file, :problem, keyword_init: true)

    def initialize(installed_dir:, gem_dirs:)
      @installed_dir = Pathname.new(installed_dir.to_s)
      @gem_dirs = Array(gem_dirs).map { |dir| Pathname.new(dir.to_s) }
    end

    # Every file in db/migrate that is RECOGNISABLY a copy of an engine
    # migration: it carries the installer's scope suffix, OR its provenance
    # header, and either is enough.
    #
    # Requiring both would be an escape hatch twice over — renaming the engine's
    # scope stops the suffix matching, and deleting the header line stops the
    # file being locatable — so a file with EITHER mark is in scope, and a file
    # that has the suffix but lost its header is REPORTED rather than skipped.
    #
    # Migrations with neither mark are out of scope on purpose. This app's
    # 20260621120000_create_studio_links.rb is hand-written, not installed — it
    # generalized turf-monster's own magic_links table into the shared store —
    # and it carries neither the suffix nor the header. Its divergence from the
    # gem's reference migration is history, not drift.
    #
    # So are OTHER engines' copies. `install:migrations` is a Rails mechanism,
    # not a studio-engine one — mcritchie-industries carries
    # `create_active_storage_tables.active_storage.rb`, a copy with the same
    # header in a different scope. Matching the header alone would drag it in
    # here and report it as unlocatable, which is why the scope is read and
    # checked rather than ignored.
    def installed
      @installed ||= @installed_dir.children
                                   .select { |path| path.file? && path.extname == ".rb" }
                                   .select { |path| path.basename.to_s.match?(SCOPED_COPY) || studio_header?(path.read) }
                                   .sort
    end

    # Copies verified identical, in code, to the gem's current file.
    def in_sync
      evaluated.select { |_path, status, _detail| status == :in_sync }.map(&:first)
    end

    # Everything this guard wants a human to look at.
    def problems
      evaluated.reject { |_path, status, _detail| status == :in_sync }
               .map { |path, _status, detail| Finding.new(name: Copies.bare_name(path), file: path, problem: detail) }
    end

    def self.bare_name(path)
      File.basename(path.to_s).sub(/\A\d+_/, "").sub(/\.[a-z_]+\.rb\z/, "").sub(/\.rb\z/, "")
    end

    # A digest of what the migration DOES: every Ripper token except layout and
    # comments. Whitespace INSIDE a string or heredoc survives, because it is a
    # token's value rather than the space between tokens — so a reformatted copy
    # matches while a copy whose message changed does not.
    def self.code_digest(source)
      tokens = Ripper.lex(source).to_a.reject { |(_pos, type, _value)| IGNORED_TOKENS.include?(type) }
      Digest::SHA256.hexdigest(tokens.map { |(_pos, type, value)| "#{type}#{value}" }.join(""))
    end

    private

      def evaluated
        @evaluated ||= installed.map { |path| evaluate(path) }
      end

      def studio_header?(source)
        match = source.match(PROVENANCE)
        match && SCOPES.include?(match[1])
      end

      def evaluate(path)
        source = path.read
        match = source.match(PROVENANCE)

        unless match
          return [ path, :unlinked,
                   "carries the installer's scope suffix but no `# This migration comes from ...` header, " \
                   "so the gem migration it was copied from cannot be identified. Restore the header, or " \
                   "acknowledge it below if this file is a hand-written adoption rather than an installed copy." ]
        end

        unless SCOPES.include?(match[1])
          return [ path, :unlinked,
                   "is named as a studio-engine copy but its header says it came from `#{match[1]}`, " \
                   "so it cannot be compared against studio-engine's migrations." ]
        end

        original = locate(match[2])

        unless original
          return [ path, :unlinked,
                   "says it was copied from engine migration #{match[2]}, which the resolved studio-engine " \
                   "(#{Studio::VERSION}) no longer ships. Either the gem dropped it or the header is wrong." ]
        end

        if Copies.code_digest(source.sub(PROVENANCE, "")) == Copies.code_digest(original.read)
          [ path, :in_sync, original ]
        else
          [ path, :drift,
            "no longer matches the gem's #{original.basename} at studio-engine #{Studio::VERSION}.\n" \
            "        gem source: #{original}\n" \
            "        Re-running `studio_engine:install:migrations` will NOT fix it — the installer skips a " \
            "migration whose name is already installed. If this migration has already run, hand-sync the body " \
            "into THIS file and keep its filename, or the copy returns renumbered and pending while the old " \
            "version stays stamped as run." ]
        end
      end

      def locate(version)
        @gem_dirs.flat_map { |dir| dir.children }
                 .select { |path| path.extname == ".rb" }
                 .find { |path| path.basename.to_s.start_with?("#{version}_") }
      end
  end

  # THE GATE. A gem-side rewrite that this app never adopted fails HERE.
  test "every installed engine migration still matches the gem's copy" do
    unacknowledged = copies.problems.reject { |finding| ACKNOWLEDGED_DRIFT.key?(finding.name) }

    assert_empty unacknowledged, <<~MSG
      installed studio-engine migrations have drifted from the gem:

      #{unacknowledged.map { |finding| "      - #{finding.file.basename}: #{finding.problem}" }.join("\n\n")}

      If a divergence is deliberate, add it to ACKNOWLEDGED_DRIFT in this file with the reason.
    MSG
  end

  # A GUARD THAT COMPARED NOTHING PASSES EVERY DAY.
  #
  # The test above is empty-set-true: if `installed` stopped recognising copies
  # — a renamed scope suffix, a reworded provenance header, a db/migrate that
  # moved — it would go green while checking zero files. So name the copy at the
  # centre of the 2026-08-13 incident and require that it was actually VERIFIED,
  # not merely un-flagged.
  test "the guard verified this app's copy of the migration the incident was about" do
    verified = copies.in_sync.map { |path| Copies.bare_name(path) }

    assert_includes verified, "add_standard_user_profile_columns",
                    "this guard did not verify the standard-profile copy. It verified #{verified.inspect}. " \
                    "Either the copy is gone from db/migrate, or the guard stopped recognising installed " \
                    "copies and is now passing vacuously."
  end

  # THE MUTATION TEST — acceptance: a stale copy must fail the guard.
  #
  # Runs against a tmpdir copy of this app's REAL db/migrate, perturbed back to
  # the shape the file had before studio-engine 4c18516: one reversible `change`,
  # no refusing `down`. That is the actual stale fork, not a toy, and it is the
  # exact file every consumer was carrying that night.
  test "a copy left on the pre-rewrite body is reported as drift" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Rails.root.join("db/migrate").children, dir)
      target = Pathname.new(dir).glob("*_add_standard_user_profile_columns.studio_engine.rb").sole

      # What this app reports BEFORE the perturbation, so the assertion below is
      # about what the mutation ADDED rather than about the app's standing state
      # — an app with an acknowledged divergence already has a finding, and an
      # end-state assertion would fail there for the wrong reason.
      before = Copies.new(installed_dir: dir, gem_dirs: gem_migration_dirs).problems.map(&:name)

      current = target.read
      stale = current.sub("  def up\n", "  def change\n").sub(/^  def down\n.*\n  end\n/m, "")
      # A mutation test that mutates nothing passes while proving nothing, and
      # the shapes it edits live in a file this repo does not own. Check.
      refute stale == current, "the mutation changed nothing — this test would prove nothing"
      target.write(stale)

      after = Copies.new(installed_dir: dir, gem_dirs: gem_migration_dirs).problems

      assert_equal [ "add_standard_user_profile_columns" ], after.map(&:name) - before,
                   "reverting the copy to its pre-rewrite body must add exactly one finding"
      assert_match(/no longer matches the gem's/,
                   after.find { |finding| finding.name == "add_standard_user_profile_columns" }.problem)
    end
  end

  # THE MUTATION TEST, FROM THE OTHER END — the drift that actually happens.
  #
  # Nobody edits an installed copy; the gem moves and the copy stays put. So
  # rewrite the GEM side and require that THIS app's real, untouched db/migrate
  # goes red until it re-syncs. The rewrite lands in a tmpdir copy of the gem's
  # migrations: the installed gem is shared with every other app on this machine
  # and is never edited.
  test "a rewrite on the gem side reddens this app's installed copy" do
    Dir.mktmpdir do |gem_dir|
      FileUtils.cp_r(Pathname.new(gem_migration_dirs.first).children, gem_dir)
      before = Copies.new(installed_dir: Rails.root.join("db/migrate"), gem_dirs: [ gem_dir ]).problems.map(&:name)

      target = Pathname.new(gem_dir).glob("*_add_standard_user_profile_columns.rb").sole
      current = target.read
      # A plausible next release: one more standard column on the same migration.
      published = current.sub("    add_column :users, :ip_locations",
                              "    add_column :users, :locale, :string, if_not_exists: true\n\n    add_column :users, :ip_locations")
      refute published == current, "the gem-side rewrite changed nothing — this test would prove nothing"
      target.write(published)

      after = Copies.new(installed_dir: Rails.root.join("db/migrate"), gem_dirs: [ gem_dir ]).problems

      assert_equal [ "add_standard_user_profile_columns" ], after.map(&:name) - before,
                   "a migration rewritten in the gem must redden this app until it re-syncs"
    end
  end

  # The header is the one difference EVERY installed copy has, so a guard that
  # counted it would flag all of them and be useless on its first run.
  test "the provenance header the installer adds is not counted as drift" do
    with_fixture_pair(installed_body: ->(gem_source) { "# This migration comes from studio_engine (originally 20260101000000)\n#{gem_source}" }) do |copies|
      assert_empty copies.problems, "the installer's own header must not read as drift"
      assert_equal 1, copies.in_sync.length
    end
  end

  # The measured mcritchie-industries case, pinned so nobody re-tightens this to
  # bytes without meeting it first.
  test "rubocop reformatting an installed copy is not counted as drift" do
    # rubocop-rails-omakase's Layout/SpaceInsideArrayLiteralBrackets, which is
    # what turned the gem's `[:category, :key]` into industries' installed
    # `[ :category, :key ]`, plus some spare blank lines for good measure.
    reformat = lambda do |gem_source|
      body = gem_source.gsub("[:", "[ :").gsub("]", " ]").gsub("\n\n", "\n\n\n")
      "# This migration comes from studio_engine (originally 20260101000000)\n#{body}"
    end

    with_fixture_pair(installed_body: reformat) do |copies|
      assert_empty copies.problems, "whitespace-only reformatting is not a behavioural change"
      assert_equal 1, copies.in_sync.length
    end
  end

  # Deleting the header would otherwise make a copy unlocatable AND invisible.
  test "a copy whose provenance header was removed is reported, not skipped" do
    with_fixture_pair(installed_body: ->(gem_source) { gem_source }) do |copies|
      assert_equal 1, copies.problems.length, "a suffixed copy with no header must still be examined"
      assert_match(/no `# This migration comes from/, copies.problems.sole.problem)
    end
  end

  # MEASURED in mcritchie-industries, whose db/migrate carries
  # `create_active_storage_tables.active_storage.rb`. `install:migrations` is a
  # RAILS mechanism, so other engines' copies wear the same provenance header —
  # and claiming them here would report Active Storage as an unlocatable
  # studio-engine migration on an app that has done nothing wrong.
  test "another engine's install-copy is not this guard's business" do
    active_storage = <<~RUBY
      # This migration comes from active_storage (originally 20170806125915)
      class CreateActiveStorageTables < ActiveRecord::Migration[7.2]
        def change
        end
      end
    RUBY

    with_fixture_pair(installed_body: ->(gem_source) { "# This migration comes from studio_engine (originally 20260101000000)\n#{gem_source}" },
                      extra_installed: { "20260506000000_create_active_storage_tables.active_storage.rb" => active_storage }) do |copies|
      assert_equal [ STUDIO_FIXTURE_COPY ], copies.installed.map { |path| path.basename.to_s },
                   "only studio-engine's copies belong to this guard"
      assert_empty copies.problems
    end
  end

  # An allowlist nobody prunes becomes a blanket exemption. This fails the day an
  # acknowledged file comes back into sync, so the entry has to be deleted.
  test "every acknowledged divergence still names a file this guard flags" do
    flagged = copies.problems.map(&:name)

    ACKNOWLEDGED_DRIFT.each do |name, reason|
      assert_includes flagged, name,
                      "ACKNOWLEDGED_DRIFT names #{name}, which no longer diverges from the gem — delete the entry"
      refute_empty reason.to_s.strip, "#{name} is acknowledged with no reason; say why the divergence stands"
    end
  end

  private

    def copies
      @copies ||= Copies.new(installed_dir: Rails.root.join("db/migrate"), gem_dirs: gem_migration_dirs)
    end

    def gem_migration_dirs
      dirs = Studio::Engine.paths["db/migrate"].existent
      assert_not_empty dirs, "the resolved studio-engine ships no db/migrate — there is nothing to compare against"
      dirs
    end

    # Builds a one-file gem dir and a one-file installed dir in tmp, so a
    # normalization rule can be stated on a KNOWN pair instead of on whatever
    # happens to be installed. The gem side is a real engine migration.
    def with_fixture_pair(installed_body:, extra_installed: {})
      Dir.mktmpdir do |root|
        gem_dir = FileUtils.mkdir_p(File.join(root, "gem")).sole
        installed_dir = FileUtils.mkdir_p(File.join(root, "installed")).sole

        source = Pathname.new(gem_migration_dirs.first).glob("*_create_studio_enumerals.rb").sole.read
        File.write(File.join(gem_dir, "20260101000000_create_studio_enumerals.rb"), source)
        File.write(File.join(installed_dir, STUDIO_FIXTURE_COPY), installed_body.call(source))
        extra_installed.each { |name, body| File.write(File.join(installed_dir, name), body) }

        yield Copies.new(installed_dir: installed_dir, gem_dirs: [ gem_dir ])
      end
    end
end
