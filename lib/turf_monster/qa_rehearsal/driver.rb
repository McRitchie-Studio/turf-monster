# frozen_string_literal: true

module TurfMonster
  module QaRehearsal
    # The rehearsal itself, as five steps an operator runs one at a time.
    #
    # Split deliberately. A single command that did the whole cycle would be
    # shorter to write and useless to watch: the value of this act is that Mr.
    # McRitchie can read what each stage did, look at the board, and decide
    # whether to go on. Each step is also independently re-runnable, so a
    # failure costs that step and not the run.
    #
    # Everything on-chain here is DEVNET. NetworkGuard runs first in every step,
    # before any key is loaded, and refuses anything else.
    class Driver
      class StepError < StandardError; end

      APP  = "turf-monster-qa"
      HOST = "qa.turfmonster.media"

      # Preseason week 4 is the evergreen slate: those games were played on
      # 2026-08-27/28, so their scores are final and identical on every run. A
      # live week would make the rehearsal's outcome depend on the day it ran.
      SLATE_NAME = "NFL 2026 Preseason Weeks 3-4"
      # A SPAN, so there are two slots to fetch and one board to watch them on.
      # The single-week form left the rehearsal on the plain tm-pair-grid, which
      # never calls TeamColorsHelper — the coloured team cards render only on the
      # multi_week branch, so the board an operator was asked to watch was the
      # uncoloured one. The span fixes that without touching a view.
      POLL_SLOTS = %w[2026:1:3 2026:1:4].freeze

      # Standard tier, matching production's world-cup-turf-totals-week-1: five
      # paid ranks over a $500 pool. With a small cast every player finishes in
      # the money, which is the point — it puts the maximum number of winner
      # accounts into the settle transaction the cast can buy.
      CONTEST_TYPE = "standard"
      MAX_ENTRIES  = 29
      ENTRY_FEE_CENTS = 1_900

      # WHO THE CONTEST IS CREATED AS, keyed on the one field that does not move.
      #
      # This was `User.find_by(slug: "alex-2")` until 2026-09-05. A User slug is
      # "#{username}-#{id}" and Sluggable rewrites it on EVERY save, so the
      # operator username swap turned that row into `mcritchie-2` and the lookup
      # would have gone nil — silently, because the `|| User.where(role: "admin")
      # .first` fallback beside it had no ORDER BY and would have handed the
      # rehearsal an arbitrary admin. If that landed on alex@mcritchie.studio the
      # server holds no key for it (KeyStore::ITEMS has no entry) and could not
      # sign as the creator it had just named. An email is the roster's own
      # primary key; nothing in the app rewrites one.
      #
      # This address is XAN (8K81…) — the shared server identity, called "Alex
      # Bot" until it was renamed on 2026-09-15. Same wallet, same key, new
      # name. It is the team@ account's wallet; the mainnet rotation
      # (mainnet-signer-records-rotation) took it off the mainnet VaultState.
      #
      # THE REHEARSAL NAMES XAN AS CREATOR BUT CANNOT SIGN AS IT, and that is
      # deliberate. The SERVER signs as Xan from SOLANA_ADMIN_KEY on the dyno;
      # KeyStore::ITEMS has no entry for it, because its 1Password item lives in
      # a vault this service account cannot read. See KeyStore::ITEMS for why
      # that separation is the control rather than a gap.
      CREATOR_EMAIL = "team@mcritchie.studio"
      SEED_COMMAND = "bin/qa-contest-rehearsal seed"
      CREATOR_MISSING = "no user on #{CREATOR_EMAIL} to create the rehearsal contest as. " \
                        "Nothing was written. Run #{SEED_COMMAND} to seed the parked " \
                        "roster on QA, then run create again."
      SEED_BUILD_BEHIND = "the build on QA has a roster seed with no adoption check, so the seed did not " \
                          "run. Nothing was written. Deploy a build that carries it, then run " \
                          "#{SEED_COMMAND} again."
      VAULT_UNREADABLE = "the devnet VaultState could not be read from QA, so the server key is not known " \
                         "to be a signer. Nothing was written. Run create again."
      SIGNER_UNSEATED = "the server key %<signer>s is not a signer in the devnet VaultState, so the create " \
                        "transaction would be refused. Nothing was written. Seat it first " \
                        "(docs/qa-signing-key-rotation.md), then run create again."
      SLATE_MISSING = "no slate named #{SLATE_NAME.inspect} on QA, so there is no board to " \
                      "rehearse on. Nothing was written."

      # Step 4's link signs this address in. Its admin role is the roster's
      # (docs/AUTH.md, Parked roles).
      COSIGNER_EMAIL = "alex@mcritchie.studio"

      # THE UNATTENDED CO-SIGN NEEDS NO ADMIN SESSION. It used to confirm the
      # settle over the admin HTTP surface as a wallet-signed-in admin, and no
      # agent-readable wallet is an admin (KeyStore::ITEMS files none), so it was
      # refused. It now confirms ON THE DYNO instead (devnet-v026-upgrade)
      # (#confirm_settle_script): the same verification primitives
      # Admin::PendingTransactionsController#confirm runs — the multisig set,
      # CosignPlan's extras, TxVerifier per signer, then mark_settled! and the
      # row — through `heroku run`, the access every other step already uses.
      #
      # IT IS v0.26-ONLY. On v0.25 the settle is the fixed 2-of-3 whose second
      # seat is Mr. McRitchie's or a mainnet signer's, so there is no devnet-only
      # agent to co-sign with; the step refuses rather than guess.
      AGENT_COSIGN_NEEDS_V026 = "--cosign agent needs turf-vault v0.26 on devnet (SOLANA_VAULT_GOVERNANCE on " \
                                "turf-monster-qa): only v0.26 seats a devnet-only agent key. Nothing was " \
                                "sent. Run `bin/qa-contest-rehearsal conclude --cosign link` and co-sign in Phantom."

      # Mack and turf, and the exclusions are not preferences:
      #
      #   * MASON cannot play: his key (CytJ…) was a mainnet VaultState signer
      #     until the mainnet rotation retired it, and the rehearsal loads no
      #     key with mainnet authority and no retired one (MainnetSignerFence).
      #
      #   * XAN cannot play, and can no longer even be asked to. Xan (8K81…) is
      #     the fee payer and contest creator, and when the player is also the
      #     fee payer the transaction needs one signature slot, not two:
      #     prepare_entry refuses with "Signer count mismatch: 2 provided
      #     (0 local + 2 additional), 1 required by the account list". That was
      #     the whole reason it sat out of this list while KeyStore still filed
      #     it. Since 2026-09-15 KeyStore files no Xan key at all — its item was
      #     renamed agent.xan.solana and moved to a vault this service account
      #     cannot read — so the exclusion is now enforced a rung lower down and
      #     this bullet records WHY, not just that.
      #   * TURF plays as the solana.turf.alex wallet (39QTL1dd), NOT as the
      #     turf-5 admin account. turf-5's username is the reserved prefix
      #     "turf" and it has no UserAccount, so the program refuses to
      #     register it; solana.turf.alex already has one, which sidesteps the
      #     whole question.
      DEFAULT_CAST = %w[mack turf].freeze

      # Agents whose filed keys may fill a v0.26 vault signer slot. The driver
      # uses only those the chain seats, never the server key twice, and never
      # a key MainnetSignerFence lists. Mason is not on it (devnet-v026-upgrade): his
      # key (CytJ…) is fenced as a retired mainnet signer, and the devnet
      # rotation evicted it from devnet. Mack (8UwJ…, since 2026-10-24) is devnet-only.
      VAULT_AGENTS = %w[mack].freeze

      attr_reader :app, :host, :cast, :io

      def initialize(app: APP, host: HOST, cast: DEFAULT_CAST, io: $stdout)
        @app = app
        @host = host
        @cast = cast
        @io = io
      end

      def guard!
        @facts ||= NetworkGuard.new(app: app).assert!
      end

      # Every key the driver loads, player or co-signer, passes the fence.
      def keys
        @keys ||= begin
          guard!
          MainnetSignerFence::FencedKeys.new(KeyStore.new, mainnet_fence)
        end
      end

      def remote
        @remote ||= RemoteRunner.new(app: app)
      end

      def manifest
        @manifest ||= Manifest.new
      end

      # --- Step 0 --------------------------------------------------------
      # Seed the parked roster on QA through the app's own seed
      # (db/seeds/users.rb). Run once per QA database; a re-run changes nothing.
      # Only roster rows and retired seats are written, and a row the seed
      # cannot prove stops it before any write (seed_adoption_refusal).
      def seed_roster
        guard!
        say "Step 0 · seed the parked roster on #{app}"

        result = remote.call(seed_script)
        raise StepError, "the seed ran and #{CREATOR_EMAIL} still has no row" unless result["creator"]

        say "  roster:  #{result['seeded'].join(', ')}"
        say "  creator: #{result['creator']} (#{CREATOR_EMAIL})"
        hand_back(verify: "the roster line names every parked username",
                  next_command: "bin/qa-contest-rehearsal create")
        result
      end

      def seed_script
        <<~RUBY
          load Rails.root.join("db/seeds/users.rb").to_s
          begin
            seeded = seed_parked_identities!(proven_only: true)
            creator = User.find_by(email: #{CREATOR_EMAIL.inspect})
            emit(seeded: seeded.values.map(&:username), creator: creator&.username)
          rescue ActiveRecord::RecordInvalid => e
            refuse("the roster seed could not save " + e.record.class.name + " " + e.record.id.to_s + ": " +
                   e.record.errors.full_messages.to_sentence)
          rescue ArgumentError => e
            raise unless e.message.include?("proven_only")

            refuse(#{SEED_BUILD_BEHIND.inspect})
          rescue SeedAdoptionRefused => e
            refuse(e.message + " Then run #{SEED_COMMAND} again.")
          end
        RUBY
      end

      # What step 1 needs, read before anything is written or sent: two rows,
      # and one chain read of who is seated in VaultState.
      def preflight_script
        <<~RUBY
          slate = Slate.find_by(name: #{SLATE_NAME.inspect})
          creator = User.find_by(email: #{CREATOR_EMAIL.inspect})
          signer = Solana::Keypair.admin.to_base58
          seated = begin
            Solana::Vault.new.read_vault_state&.dig(:active_signers)
          rescue StandardError
            nil
          end
          emit(
            creator: creator&.username,
            slate: slate&.name,
            server_signer: signer,
            signer_listed: Solana::Config::MULTISIG_SIGNERS.include?(signer),
            signer_seated: seated && seated.include?(signer),
            cosigner: Solana::Config::MULTISIG_COSIGNER
          )
        RUBY
      end

      def preflight!
        facts = remote.call(preflight_script)
        raise StepError, CREATOR_MISSING unless facts["creator"]
        raise StepError, SLATE_MISSING unless facts["slate"]
        raise StepError, VAULT_UNREADABLE if facts["signer_seated"].nil?
        raise StepError, format(SIGNER_UNSEATED, signer: facts["server_signer"]) unless facts["signer_seated"]

        say "  creator: #{facts['creator']} (#{CREATOR_EMAIL})"
        say "  server signs as #{facts['server_signer']} · co-signer #{facts['cosigner']}"
        unless facts["signer_listed"]
          say "  ! the server key is not in this app's SOLANA_MULTISIG_SIGNERS list " \
              "(docs/qa-signing-key-rotation.md, step 8)"
        end
        facts
      end

      # --- Step 1 --------------------------------------------------------
      # Create the contest, funding its prize pool from the admin wallet.
      #
      # Uses the server-funded path (Contest#create_onchain! via after_create_commit)
      # rather than the Phantom create flow. That is a deliberate narrowing: the
      # browser create path is already exercised in production and by the e2e
      # suite, while the steps this rehearsal exists for — entry, grade, settle,
      # payout — are the ones nothing routinely covers.
      def create_contest
        guard!
        say "Step 1 · create contest on #{app} (#{CONTEST_TYPE} tier)"
        preflight!

        result = remote.call(<<~RUBY)
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          creator = User.find_by(email: #{CREATOR_EMAIL.inspect})
          raise #{CREATOR_MISSING.inspect} if creator.nil?
          vault = Solana::Vault.new

          admin = Solana::Keypair.admin.to_base58

          # The prize pool is transferred from the admin wallet at create time,
          # so top it up first. Only the devnet test mint's authority can mint;
          # a server key that is not the authority must already hold the pool.
          vault.ensure_ata(admin, mint: Solana::Config::USDC_MINT)

          # The pool is denominated in CENTS in Rails and in 6-decimal base
          # units on-chain. Comparing the two directly is how a 500-dollar pool
          # turns into a 50-cent mint, so convert once and compare in one unit.
          needed_cents = Contest::FORMATS.fetch(#{CONTEST_TYPE.inspect})[:payouts].values.sum
          needed = Solana::Config.cents_to_base_units(needed_cents)
          ata, = Solana::SplToken.find_associated_token_address(admin, Solana::Config::USDC_MINT)
          ata_b58 = Solana::Keypair.encode_base58(ata)
          have = (Solana::Config.client.get_token_account_balance(ata_b58)["value"]["amount"].to_i rescue 0)
          minted = nil
          if have < needed
            begin
              minted = vault.mint_spl(needed * 4, mint: Solana::Config::USDC_MINT, to: admin)[:signature]
            rescue StandardError => e
              refuse("the server key " + admin + " holds " + (have / 1_000_000).to_s + " devnet USDC, the pool needs " +
                     (needed / 1_000_000).to_s + ", and the mint failed (" + e.class.name + ": " + e.message.to_s[0, 200] +
                     "). No contest was created. Only the mint authority can mint: fund the USDC account of " +
                     "that key, or move the authority to it (docs/qa-signing-key-rotation.md, step 4).")
            end

            # WAIT FOR THE BALANCE, NOT FOR A CLOCK. A confirmed mint is not
            # immediately visible to the node that simulates the next
            # transaction, and the prize-pool transfer then fails with SPL
            # error 0x1 (insufficient funds) -- which reads like the mint never
            # happened. A fixed sleep either wastes time or is too short on the
            # run that matters; polling the number we actually depend on is
            # neither.
            20.times do
              have = (Solana::Config.client.get_token_account_balance(ata_b58)["value"]["amount"].to_i rescue 0)
              break if have >= needed

              sleep 1
            end
            raise "minted but the admin balance never reached the pool size" if have < needed
          end

          # TIME-SHIFT THE FIXTURE INTO THE FUTURE.
          #
          # The evergreen slate is a week that has already been played, which is
          # exactly what makes its scores stable -- and exactly what makes it
          # unpickable: SlateMatchup#locked? keys off the game's kickoff, so
          # every pick is refused with "Game has already started". Nudging the
          # whole week forward, preserving the gaps between kickoffs, makes the
          # board enterable without changing what the games ARE. Step 3 puts the
          # clock back before it polls, so nothing downstream sees a fixture
          # pretending to be tomorrow.
          games = Game.where(slug: slate.slate_matchups.pluck(:game_slug).compact.uniq).to_a
          earliest = games.filter_map(&:kickoff_at).min
          shift = earliest ? (2.hours.from_now - earliest).to_i : 0
          if shift.positive?
            games.each { |g| g.update_columns(kickoff_at: g.kickoff_at + shift.seconds) if g.kickoff_at }
          end

          contest = Contest.create!(
            name: "QA Rehearsal " + Time.current.strftime("%b %-d %H:%M"),
            slate: slate,
            contest_type: #{CONTEST_TYPE.inspect},
            status: "open",
            max_entries: #{MAX_ENTRIES},
            entry_fee_cents: #{ENTRY_FEE_CENTS},
            starts_at: 8.hours.from_now,
            user: creator
          )

          emit(
            contest_slug: contest.slug,
            name: contest.name,
            onchain: contest.onchain?,
            picks_required: contest.picks_required,
            payouts: contest.payouts,
            prize_pool_cents: contest.guaranteed_prize_cents,
            # PICKABLE rows, not every matchup: the rehearsal slate is a span,
            # and the pick endpoints refuse the later-week row of a team.
            # Spelled with pickable_matchups, not pickable_matchup_ids, because
            # this runs inside the DEPLOYED app, which may be a release behind.
            matchup_ids: contest.pickable_matchups.map(&:id).sort,
            locks_at: contest.starts_at&.iso8601,
            minted: minted,
            kickoff_shift_seconds: shift
          )
        RUBY

        unless result["onchain"]
          raise StepError, "contest #{result['contest_slug']} was created but never landed on-chain"
        end

        manifest.write(result.merge("app" => app, "host" => host, "cast" => cast))

        say "  contest:  #{result['contest_slug']} (#{result['name']})"
        say "  on-chain: yes · pool $#{result['prize_pool_cents'].to_i / 100} · payouts #{result['payouts'].inspect}"
        say "  picks:    #{result['picks_required']} from #{result['matchup_ids'].size} matchups"
        say "  locks at: #{result['locks_at']}"
        say_urls(result["contest_slug"])
        hand_back(verify: "the contest reads $500 Prizes, $19 Entry, 0/29 Entries, cards unlocked",
                  next_command: "bin/qa-contest-rehearsal enter")
        result
      end

      # --- Step 2 --------------------------------------------------------
      # Enter each cast member through the real player path (see EntryFlow).
      #
      # Each player gets a DIFFERENT slice of the board. The contest refuses two
      # entries with an identical pick combination, so handing everyone the same
      # first six matchups would enter the first player and bounce the rest with
      # a message about duplicates that says nothing about the real cause.
      def enter_cast
        guard!
        data = manifest.read
        slug = data.fetch("contest_slug")
        picks_required = data.fetch("picks_required")
        matchups = data.fetch("matchup_ids")
        say "Step 2 · enter #{cast.size} player(s) into #{slug}"

        results = cast.each_with_index.map do |who, index|
          slice = matchups.rotate(index * picks_required).first(picks_required)
          say "  #{who}: picks #{slice.inspect}"

          session = WalletSession.new(host: host, keypair: keys.keypair(who))
          session.sign_in!

          begin
            result = EntryFlow.new(session: session, contest_slug: slug,
                                   matchup_ids: slice, picks_required: picks_required).call
            say "    entered · entry #{result['entry_id']} · tx #{result['tx_signature'].to_s[0, 16]}… " \
                "· #{result['token_funded'] ? 'token' : 'USDC'}-funded"
            { who: who, ok: true, entry_id: result["entry_id"], tx: result["tx_signature"] }
          rescue EntryFlow::EntryError => e
            # One player failing must not abort the others — a partial field is
            # still a runnable rehearsal, and the operator wants to see WHICH
            # player failed rather than only the first.
            say "    FAILED · #{e.message}"
            { who: who, ok: false, error: e.message }
          end
        end

        manifest.merge("entries" => results)
        failed = results.reject { |r| r[:ok] }
        say failed.empty? ? "  all #{results.size} entered" : "  #{failed.size} of #{results.size} FAILED"
        say_urls(slug)
        hand_back(verify: "entries read #{results.count { |r| r[:ok] }}/29 and every player sits on the leaderboard at 0",
                  next_command: "bin/qa-contest-rehearsal play   (unattended; add --pace 4 to watch it)")
        results
      end

      # --- Step 3 --------------------------------------------------------
      # Replay the preseason and let the real poller write the scores.
      #
      # Two halves on purpose. The reset puts the slate back to kickoff so every
      # run replays from zero — without it the second run finds the games
      # already final and the board never moves. The poll is Turf Monster's own
      # `live-score-watch` entry point, unchanged and pointed at one slot, so
      # what lands here is real ESPN data through the real chain: Goal rows,
      # Game#update_slate_matchups!, contest re-score, live broadcast.
      #
      # THREE MODES, named by the flags (Options):
      #   pace: nil, replay: true   unattended — every play re-laid back to back,
      #                             then the catch-up check (#replay_script)
      #   pace: 4,   replay: true   watched — the same replay, 4 s apart
      #   replay: false             poll only — the burst, no per-play chain
      # A pace of 0 is refused: it used to MEAN poll-only, so a run that looked
      # fast had skipped the very chain it was meant to rehearse.
      def play_preseason(reset: true, pace: nil, replay: true)
        per_play = replay
        check_pace!(pace, per_play)
        guard!
        data = manifest.read
        say "Step 3 · run the preseason for #{data['contest_slug']}"

        # LOCK BEFORE THE GAMES PLAY. A contest locks at kickoff and then the
        # games happen — doing it the other way leaves the board open while its
        # fixtures conclude, and `Contest#live?` is `locked? && !settled?`, so
        # the per-contest LIVE PAGE — the one built for watching this — redirects
        # for the entire watchable window. Step 1 sets the lock hours out so the
        # cast can enter; this is where that stops being true.
        lock_contest(data.fetch("contest_slug"))

        # A PACED RUN MUST NOT POLL FIRST when the slate already holds its goals.
        # The poll writes the whole week in one burst, so the operator watches a
        # finished board for ~3 minutes before the replay clears it and starts
        # over — a spoiler followed by a rewind. The replay captures, clears and
        # re-lays what is already there, so on a slate that has been fetched
        # before, the fetch is not just redundant, it is the thing that ruins it.
        # An unattended replay skips it for the same reason and one more: two
        # dyno boots and a full ESPN fetch buy nothing the captured rows lack.
        if per_play && slate_already_scored?
          say "  slate already holds its real plays — skipping the fetch and replaying from a clean board"

          # UNSHIFT ON THIS PATH TOO. Step 1 nudges the whole week into the
          # future so the board is pickable; putting the clock back used to live
          # inside the `if reset` block below, which this return jumps over. So
          # every paced re-run left the fixture claiming to kick off tomorrow
          # while its games read FINAL — the exact incoherence the unshift
          # exists to prevent, on the path an operator uses most.
          unshift_fixture(data["kickoff_shift_seconds"].to_i)
          # THROUGH THE TAIL, never around it. This `return` has now eaten a
          # tail behaviour twice: first the unshift (387d9a2a), then the halt
          # itself, which shipped unhalted on the branch an operator uses most
          # while a source-scanning test stayed green. Both exits end in
          # finish_play for that reason — there is no longer a tail to jump.
          return finish_play(data, replay(pace))
        end

        if reset
          # Undo step 1's time-shift FIRST, through the SAME method the paced
          # path uses. This used to be a second inline copy, and the comment
          # claiming the two were "extracted so they cannot drift" was false
          # while two implementations sat here differing in their guards.
          unshift_fixture(data["kickoff_shift_seconds"].to_i)

          cleared = remote.call(<<~RUBY)
            slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
            slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq

            goals = Goal.where(game_slug: slugs).delete_all
            games = Game.where(slug: slugs).update_all(home_score: nil, away_score: nil,
                                                       status: "scheduled", status_detail: nil)
            ms = slate.slate_matchups.update_all(goals: nil, status: "pending")
            zeroed = Entry.where(contest_id: Contest.where(slate_id: slate.id).select(:id))
                          .where.not(score: 0).update_all(score: 0)
            emit(goals_deleted: goals, games_reset: games, matchups_reset: ms, scores_zeroed: zeroed)
          RUBY
          say "  reset: #{cleared['goals_deleted']} goals, #{cleared['games_reset']} games, " \
              "#{cleared['matchups_reset']} matchups back to kickoff, " \
              "#{cleared['scores_zeroed']} score(s) zeroed"
        end

        say_urls(data.fetch("contest_slug"), live_first: true)
        say ""
        poll_slots!

        finish_play(data, per_play ? replay(pace) : nil)
      end

      PACE_REFUSED = "a replay pace must be nil (unattended, no pause) or more than 0 seconds; " \
                     "got %<pace>s. For poll-only, pass replay: false (--no-replay)."

      def check_pace!(pace, per_play)
        return if pace.nil?
        return if pace.is_a?(Numeric) && pace.positive? && per_play

        raise StepError, format(PACE_REFUSED, pace: pace.inspect) unless pace.is_a?(Numeric) && pace.positive?

        raise StepError, "a pace was given with replay: false — a poll-only run re-lays nothing to pace"
      end

      # The one tail step 3 has. Both exits return through it, so a branch added
      # later cannot skip the halt by returning early — the mistake this method
      # has now made twice.
      def finish_play(data, result)
        say_urls(data.fetch("contest_slug"), live_first: true)
        hand_back(verify: "the live board built from zero and every game reads FINAL",
                  next_command: "bin/qa-contest-rehearsal conclude --cosign agent   (or --cosign link to co-sign in Phantom)")
        result
      end

      # Put the fixture's clock back where step 1 found it.
      #
      # Extracted so the paced path and the reset path cannot drift: the poller
      # matches ESPN by slot and external id, never by our clock, so this is
      # cosmetic to the FETCH — but a board showing tomorrow's date beside a
      # final score is what makes an operator distrust a run that is fine.
      # IDEMPOTENT BY CLEARING THE SHIFT IT CONSUMED.
      #
      # `kickoff_shift_seconds` was written once by step 1 and never cleared. On
      # the RESET path that was survivable by accident — the ESPN poll re-anchors
      # kickoff_at seconds later — but the paced path SKIPS that poll, so a
      # second run moved the fixture to real−S and a third to real−2S, walking
      # the whole week backwards into the past a run at a time.
      #
      # Recording that it has been spent is what makes re-running a step safe,
      # which is the property every step in this driver is supposed to have.
      def unshift_fixture(shift)
        return if shift <= 0

        remote.call(<<~RUBY)
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq
          moved = 0
          Game.where(slug: slugs).find_each do |g|
            next unless g.kickoff_at

            g.update_columns(kickoff_at: g.kickoff_at - #{shift}.seconds)
            moved += 1
          end
          emit(unshifted: moved)
        RUBY
        manifest.merge("kickoff_shift_seconds" => 0)
        say "  fixture clock put back (#{shift}s)"
      end

      # Does the slate already carry the real Goal rows a replay can re-lay?
      def slate_already_scored?
        remote.call(<<~RUBY).fetch("goals").positive?
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq
          emit(goals: Goal.where(game_slug: slugs).count)
        RUBY
      end

      def lock_contest(slug)
        locked = remote.call(lock_script(slug))
        locked = agent_cosigned_lock(slug, locked) unless locked.key?("locked")
        say "  contest locked: #{locked['locked']} · live page: #{locked['live'] ? 'open' : 'closed'}"
      end

      # v0.25: the server sets the lock alone, as it always has. v0.26: with
      # no cosigners it answers what the lock needs; with enough, it answers
      # a server-signed wire for them to sign.
      def lock_script(slug, cosigners: [])
        <<~RUBY
          contest = Contest.find_by!(slug: #{slug.inspect})
          if contest.locked? || !Solana::Config.governance?
            unless contest.locked?
              Solana::Vault.new.set_contest_lock_time(contest.slug, Time.current.to_i)
              contest.update!(starts_at: Time.current)
            end
            emit(locked: contest.reload.locked?, live: contest.live?)
          else
            vault = Solana::Vault.new
            action = vault.governed_time_action("set_contest_lock_time", contest.slug)
            #{cosign_or_build_ruby(cosigners, named: 1,
                                   build: 'vault.build_agent_cosigned_contest_time("set_contest_lock_time", ' \
                                          "contest.slug, Time.current.to_i, cosigner_pubkeys: cosigners)")}
          end
        RUBY
      end

      # `answer` is the v0.26 lock script's first reply: a cosign request, or
      # a finished wire when the chain needs no agent.
      def agent_cosigned_lock(slug, answer)
        agents = answer["cosign"] ? pick_agents(answer["cosign"]) : []
        built = answer["cosign"] ? remote.call(lock_script(slug, cosigners: agents.map(&:to_base58))) : answer
        raise StepError, "the lock wire did not come back: #{built.inspect}" unless built["serialized_tx"]

        say "  lock co-signed by #{agents.map { |a| a.to_base58[0, 4] }.join(', ')}: #{sign_and_send(built, agents)}"
        remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          contest.update!(starts_at: Time.current)
          emit(locked: contest.reload.locked?, live: contest.live?)
        RUBY
      end

      # EVERY slot must land, not just the last. A span whose second week fetched
      # and whose first did not is a half-scored board that still looks
      # plausible — one week final, the other reading as "not kicked off yet" —
      # and `conclude` would grade and settle real money against it.
      #
      # The return value IS the verdict. By the time this runs the board has
      # ALREADY been cleared, so a failure has to stop the step rather than be
      # logged and stepped over.
      def poll_slots!
        say "  polling ESPN slots #{POLL_SLOTS.join(', ')} …"

        POLL_SLOTS.each do |slot|
          next if system("heroku", "run", "--app", app, "--no-tty", "--exit-code", "--",
                         "bin/nfl-live-poll", "--slot", slot)

          raise StepError, "the ESPN poll failed for slot #{slot} — the board is CLEARED and " \
                           "no scores landed. Re-run step 3 before concluding."
        end
      end

      # Replay the week one scoring play at a time.
      #
      # This is a REPLAY, not a simulation. The poll has already written the
      # real Goal rows; this captures them, deletes them, and writes them back
      # one at a time. Every re-created Goal fires the same callbacks the feed
      # fires — refresh_game_scores, the contest re-score, and BOTH live
      # broadcasts — so what appears on /live is the real touchdown, arriving
      # on a clock we choose.
      #
      # THE PACE IS ONLY FOR EYES. `pace: nil` (the unattended gauntlet) runs
      # the same loop with no pause: the same rows, the same order, the same
      # callbacks, the same conclude after each game's last play. At --pace 4
      # the pause was ~4 of every ~5.3 s per play on QA, so the week took ~20
      # minutes to wait, not to compute.
      #
      # It runs entirely on the dyno, in ONE invocation, and streams. A version
      # that reached back to Rails per play would cost a dyno per touchdown.
      def replay(pace)
        say ""
        if pace
          say "  replaying #{POLL_SLOTS.join(' + ')} at #{pace}s per scoring play — watch https://#{host}/live"
        else
          say "  replaying #{POLL_SLOTS.join(' + ')} unattended: every scoring play, back to back, then the catch-up check"
        end

        script = replay_script(pace)

        # The streaming path bypasses RemoteRunner, so it borrows its guard
        # rather than rediscovering the shell-expansion bug on its own.
        if script.match?(RemoteRunner::SHELL_EXPANDABLE)
          raise StepError, "replay script contains a shell-expandable name — see RemoteRunner::SHELL_EXPANDABLE"
        end

        # --exit-code: without it `heroku run` exits 0 whatever the dyno's command
        # returned, so a CATCH-UP FAILED raise would hand on to conclude.
        return if system("heroku", "run", "--app", app, "--no-tty", "--exit-code", "--", "bin/rails", "runner", script)

        raise StepError, "the replay failed partway, or its catch-up check did not pass (the replay: lines " \
                         "above say which). Do not conclude on this board. Re-run step 3."
      end

      # The Ruby the dyno runs for step 3's replay. Public so a test can run
      # it against a real database: it is the step's whole behaviour.
      #
      # THE CATCH-UP CHECK closes it, and it is what makes dropping the pause
      # safe. The per-play chain is synchronous today (Goal callbacks, the
      # contest re-score and both broadcasts run inline; nothing is enqueued),
      # so a fast replay cannot outrun it — but that is a fact about today's
      # code, and a sleep would only have hidden the day it stopped being true.
      # So before `conclude` may grade, the board must PROVE it caught up:
      #   * every captured play is back on the slate, and every game that had
      #     one reads completed;
      #   * each game's score equals the sum of its plays, and each of its
      #     slate matchups carries that score, marked completed;
      #   * every entry in every open contest on the slate scores what a fresh
      #     recompute gives (Selection#computed_points, the same formula
      #     Entry#score! writes);
      #   * nothing was rescued into ErrorLog while it ran — a broadcast that
      #     raises is swallowed, and the log is the only thing that notices.
      # Any miss prints `replay: CATCH-UP FAILED — …` and exits non-zero.
      def replay_script(pace)
        pause = pace ? "sleep #{Float(pace)}" : "# unattended: no pause; the catch-up check below proves the chain kept up"

        <<~RUBY
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq
          kickoffs = Game.where(slug: slugs).pluck(:slug, :kickoff_at).to_h
          started_at = Time.current

          # Capture the real plays, then take them off the board. Ordered by
          # kickoff then game clock, so simultaneous games interleave the way a
          # Sunday actually does rather than finishing one at a time.
          captured = Goal.where(game_slug: slugs).map { |g| g.attributes.except("id", "slug") }
          captured.sort_by! { |g| [kickoffs[g["game_slug"]] || Time.current, g["minute"].to_i, g["created_at"].to_s] }

          Goal.where(game_slug: slugs).delete_all
          Game.where(slug: slugs).update_all(home_score: nil, away_score: nil,
                                             status: "scheduled", status_detail: nil)
          slate.slate_matchups.update_all(goals: nil, status: "pending")
          # ZERO THE LEADERBOARD TOO. Clearing the goals does not clear the
          # scores derived from them -- nothing re-scores an entry until the next
          # goal lands, so the board keeps showing last run's totals while the
          # games sit at 0-0. An operator reading that cannot tell how much
          # football is left to play, which is the whole point of watching a
          # paced replay.
          zeroed = Entry.where(contest_id: Contest.where(slate_id: slate.id).select(:id))
                        .where.not(score: 0).update_all(score: 0)
          open_contests = Contest.where(slate_id: slate.id, status: "open").count
          puts "replay: board cleared, \#{captured.size} plays queued, \#{zeroed} score(s) zeroed, " \
               "\#{open_contests} open contest(s) re-scored per play"
          STDOUT.flush

          remaining = captured.group_by { |g| g["game_slug"] }.transform_values(&:size)
          clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          work = []
          began = clock.call

          captured.each_with_index do |attrs, i|
            t = clock.call
            goal = Goal.create!(attrs)
            game = goal.game
            puts format("replay: %3d/%d  %-4s %-12s +%-2s  %s %s-%s %s",
                        i + 1, captured.size, goal.team_slug.to_s[0, 4].upcase,
                        goal.scoring_type, goal.points,
                        game.away_team_slug.to_s[0, 3].upcase,
                        game.away_score, game.home_score,
                        game.home_team_slug.to_s[0, 3].upcase)
            STDOUT.flush

            # A game concludes right after its last play, which is what flips
            # its matchups final and re-scores the contests that hold them.
            remaining[goal.game_slug] -= 1
            if remaining[goal.game_slug] <= 0
              game.reload.conclude!
              puts "replay: FINAL  \#{game.slug}"
              STDOUT.flush
            end
            work << (clock.call - t)

            #{pause}
          end

          sorted = work.sort
          mean_ms = sorted.empty? ? 0 : (sorted.sum / sorted.size * 1000).round
          p95_ms = sorted.empty? ? 0 : (sorted[(sorted.size * 0.95).ceil - 1] * 1000).round
          puts "replay: done — \#{captured.size} plays, \#{remaining.size} games in \#{(clock.call - began).round}s " \
               "(work per play \#{mean_ms}ms mean, \#{p95_ms}ms p95)"
          STDOUT.flush

          # THE CATCH-UP CHECK (see Driver#replay_script).
          problems = []
          on_board = Goal.where(game_slug: slugs).count
          problems << "\#{on_board} plays on the slate, \#{captured.size} replayed" unless on_board == captured.size

          Game.where(slug: remaining.keys).includes(:goals).find_each do |g|
            problems << "\#{g.slug} reads \#{g.status}, not completed" unless g.status == "completed"
            home = g.goals.select { |x| x.team_slug == g.home_team_slug }.sum(&:points)
            away = g.goals.select { |x| x.team_slug == g.away_team_slug }.sum(&:points)
            next if g.home_score == home && g.away_score == away

            problems << "\#{g.slug} reads \#{g.away_score}-\#{g.home_score}, its plays sum to \#{away}-\#{home}"
          end

          slate.slate_matchups.where(game_slug: remaining.keys).includes(:game).find_each do |m|
            want = m.team_slug == m.game.home_team_slug ? m.game.home_score : m.game.away_score
            next if m.goals == want && m.status == "completed"

            problems << "matchup \#{m.id} (\#{m.team_slug}) reads \#{m.goals.inspect} \#{m.status}, its game says \#{want.inspect} completed"
          end

          entries_checked = 0
          Contest.where(slate_id: slate.id, status: "open").find_each do |contest|
            contest.entries.where(status: [:active, :complete]).includes(:selections).find_each do |entry|
              fresh = entry.selections.sum { |s| s.computed_points || s.points || 0 }.to_f
              entries_checked += 1
              next if (entry.score.to_f - fresh).abs < 0.001

              problems << "entry \#{entry.id} in \#{contest.slug} scores \#{entry.score}, a fresh recompute gives \#{fresh}"
            end
          end

          # An empty board must not read as caught up: no plays, or no entry
          # checked, means the comparisons above proved nothing.
          problems << "no plays were captured on the slate, so nothing was replayed" if captured.empty?
          problems << "no entry in an open contest on the slate was checked" if entries_checked.zero?

          logged = ErrorLog.where("created_at >= ?", started_at)
          unless logged.none?
            problems << "\#{logged.count} error(s) rescued into ErrorLog during the replay: " +
                        logged.order(:id).limit(3).pluck(:message).map { |m| m.to_s[0, 120] }.join(" | ")
          end

          if problems.empty?
            puts "replay: caught up — \#{on_board} plays on the board, \#{remaining.size} games final, " \
                 "\#{entries_checked} entry score(s) equal a fresh recompute, no errors logged"
          else
            problems.each { |problem| puts "replay: CATCH-UP FAILED — " + problem }
            STDOUT.flush
            raise "replay catch-up check failed: \#{problems.size} problem(s)"
          end
        RUBY
      end

      # --- Step 4 --------------------------------------------------------
      # Lock, grade, and settle.
      #
      # grade! refuses while the contest is unlocked (the program rejects a
      # settle before lock, so grading first would only fail later and louder),
      # which is why the lock is not set at create time — the cast needs an open
      # contest in step 2.
      #
      # STEP 3 now does the locking (see #play_preseason), because a contest
      # locks at kickoff and THEN the games play. This kept saying the lock was
      # moved "here" long after it moved again, which is how a reader ends up
      # looking for it in the wrong step. The call below stays as a backstop for
      # a run that concludes without a step 3.
      def conclude(cosign: :agent)
        raise StepError, "unknown --cosign #{cosign.inspect}: use agent or link" unless %i[agent link].include?(cosign)

        guard!
        data = manifest.read
        slug = data.fetch("contest_slug")
        say "Step 4 · conclude #{slug}"

        # Before the lock, the grade or any broadcast: the unattended path is
        # v0.26-only, so a v0.25 dyno is refused while nothing has moved.
        if cosign == :agent && !remote.call("emit(governance: Solana::Config.governance?)")["governance"]
          raise StepError, AGENT_COSIGN_NEEDS_V026
        end

        graded = remote.call(grade_script(slug))
        if graded["cosign"]
          # v0.26: the lock needs an agent signature, so it lands first and the
          # grade runs again on a locked contest.
          agent_cosigned_lock(slug, graded)
          graded = remote.call(grade_script(slug))
        end

        say "  graded: #{graded['status']} · #{graded['winners'].size} winner(s)"
        graded["winners"].each do |w|
          say "    ##{w['rank']} #{w['user']} $#{w['payout_cents'].to_i / 100} (#{w['wallet'].to_s[0, 8]}…)"
        end

        manifest.merge("ptx_slug" => graded["ptx_slug"], "winners" => graded["winners"])

        say_urls(slug)

        if graded["ptx_slug"].blank?
          say "  no settle transaction to co-sign (nobody was owed)"
          return hand_back(verify: "the contest graded with no winner owed a payout",
                           next_command: "bin/qa-contest-rehearsal close")
        end

        cosign == :link ? offer_cosign_link(graded) : cosign_with_agent(graded)
      end

      # Lock (v0.25), grade, and report the settle row. Re-runnable: grading
      # is skipped on a contest that already has its ranks.
      def grade_script(slug)
        <<~RUBY
          contest = Contest.find_by!(slug: #{slug.inspect})
          raise "\#{contest.slug} was cancelled on chain; it cannot be graded" if contest.cancelled?
          vault = Solana::Vault.new

          # v0.26: the lock needs an agent signature the dyno does not hold, so
          # ask for it and stop; conclude lands the lock and runs this again.
          if !contest.locked? && Solana::Config.governance?
            action = vault.governed_time_action("set_contest_lock_time", contest.slug)
            #{cosign_request_ruby(named: 1)}
            exit
          end

          # Move the lock to NOW, on-chain first (the chain is master) and then
          # mirror it in the DB, exactly as confirm_lock_time does.
          unless contest.locked?
            vault.set_contest_lock_time(contest.slug, Time.current.to_i)
            contest.update!(starts_at: Time.current)
          end

          # grade! raises on an already-settled contest, and a settle that was
          # graded but never co-signed is EXACTLY the state a re-run needs to
          # recover -- it is the same state production's
          # turf-totals-alpha-contest-v1 has been stuck in since June. So grade
          # only when there is grading left to do, and let the co-sign below
          # pick up a contest that already has its ranks.
          contest.grade! unless contest.graded?
          contest.reload
          ptx = PendingTransaction.where(target: contest, tx_type: "settle_contest").order(:id).last
          winners = contest.entries.complete.where("payout_cents > 0").order(:rank).map do |e|
            { entry: e.id, user: e.user&.slug, rank: e.rank, payout_cents: e.payout_cents,
              wallet: e.user&.solana_address }
          end

          emit(status: contest.status, onchain_settled: contest.onchain_settled,
               ptx_slug: ptx&.slug, ptx_status: ptx&.status, winners: winners)
        RUBY
      end

      # --- Step 5 --------------------------------------------------------
      def close_contest
        guard!
        data = manifest.read
        slug = data.fetch("contest_slug")
        say "Step 5 · reclaim rent on #{slug}"

        result = remote.call(close_script(slug))
        result = agent_cosigned_close(slug, result) unless result.key?("already_closed")

        say "  closed: #{result.inspect}"
        say_urls(slug)
        hand_back(verify: "the contest reads settled and the rent came back")
        result
      end

      # Closing sweeps the prize pool, so an unpaid contest is refused.
      # v0.26 follows lock_script's shape: a request first, then a wire.
      def close_script(slug, cosigners: [])
        <<~RUBY
          contest = Contest.find_by!(slug: #{slug.inspect})
          unless contest.onchain_settled? || contest.cancelled?
            refuse("contest " + contest.slug + " has not settled on chain, and closing sweeps its prize pool. " +
                   "On the Treasury page, press Co-sign on a Pending row, or Reconcile on a row that reads " +
                   "Broadcast · unreconciled. Run close again once the row reads Confirmed.")
          end
          out = { already_closed: contest.onchain_closed }
          if contest.onchain_closed? || !Solana::Config.governance?
            unless contest.onchain_closed?
              sig = Solana::Vault.new.close_contest(contest.slug)
              signature = sig.is_a?(Hash) ? sig[:signature] : sig
              # Only stamp the flag on a signature we actually got back. Setting
              # it unconditionally makes the DB claim a close that never landed,
              # and the rent stays unreclaimed with nothing left to say so.
              raise "close_contest returned no signature" if signature.to_s.empty?

              contest.update!(onchain_closed: true)
              out[:signature] = signature
            end
            emit(**out)
          else
            vault = Solana::Vault.new
            action = "close_contest"
            #{cosign_or_build_ruby(cosigners, named: 1,
                                   build: "vault.build_close_contest(contest.slug, cosigner_pubkey: cosigners.first, " \
                                          "extra_cosigners: cosigners.drop(1))")}
          end
        RUBY
      end

      # Same shape as #agent_cosigned_lock.
      def agent_cosigned_close(slug, answer)
        agents = answer["cosign"] ? pick_agents(answer["cosign"]) : []
        built = answer["cosign"] ? remote.call(close_script(slug, cosigners: agents.map(&:to_base58))) : answer
        raise StepError, "the close wire did not come back: #{built.inspect}" unless built["serialized_tx"]

        signature = sign_and_send(built, agents)
        remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          contest.update!(onchain_closed: true)
          emit(already_closed: false, signature: #{signature.to_s.inspect})
        RUBY
      end

      private

      # The unattended half, devnet v0.26 only. The dyno answers what the
      # settle needs beyond the server's own signature (the chain's threshold:
      # 2 on devnet, devnet-v026-upgrade, so one agent); the driver picks that many
      # seated, unfenced agent keys, the first of which is the NAMED cosigner and
      # the rest ride as extras. Everything the server does afterwards —
      # TxVerifier, the onchain_settled flip, the winner emails — is the same
      # code the Treasury page's confirm runs (#confirm_settle_script).
      def cosign_with_agent(graded)
        slug = manifest.read.fetch("contest_slug")
        request = remote.call(settle_request_script).fetch("cosign")
        raise StepError, "settle_contest needs no agent signature on this chain; nothing to co-sign" if request["needed"].to_i < 1

        agents = pick_agents(request)
        primary, *extras = agents
        say "  co-signing as #{agents.map { |a| a.to_base58[0, 4] }.join(', ')} (devnet agent key)"

        # The stored PendingTransaction reserves a signature slot for whoever
        # Solana::Config::MULTISIG_COSIGNER names -- by default Mr. McRitchie's
        # Phantom. The agent is a valid vault signer but not in THAT
        # transaction's account list, so signing it fails with "not a required
        # signer". The unattended path therefore builds its own wire naming the
        # agent, and leaves the stored one alone for the browser path to use.
        wire = remote.call(settle_build_script(slug, primary.to_base58, extras.map(&:to_base58)))
        raise StepError, "the settle wire did not come back: #{wire.inspect}" unless wire["serialized_tx"]

        # Solana::Config.client, never Solana::Client.new: a raw client falls
        # through to the gem's ENV.fetch("SOLANA_RPC_URL", <public devnet>) and
        # so FAILS OPEN, where Solana::Config::RPC_URL fails closed (OPSEC-012).
        #
        # THE ROW IS STAMPED BEFORE THE BROADCAST, as
        # Admin::PendingTransactionsController#broadcast does: the signature is
        # the first 64 bytes of the signed wire, so the row is claimed
        # `submitted` with it before the bytes leave. A send that then fails
        # leaves a row naming its transaction (the Treasury page's Reconcile
        # asks the chain), never a pending row a second run could re-send.
        ptx_slug = graded.fetch("ptx_slug")
        signed = sign_wire(wire, agents)
        signature = Solana::Keypair.encode_base58(Solana::WireMessage.parse_base64(signed).signatures.first)
        remote.call(claim_settle_script(ptx_slug, primary.to_base58, signature))
        Solana::Config.client.send_and_confirm(signed)
        say "  broadcast: #{signature}"

        confirmed = remote.call(confirm_settle_script(ptx_slug, primary.to_base58,
                                                      extras.map(&:to_base58), signature))
        say "  confirmed: #{confirmed.inspect}"
        hand_back(verify: "the payout arithmetic — the pool fell by exactly the sum paid, " \
                          "and each winner rose by exactly their rank",
                  next_command: "bin/qa-contest-rehearsal close")
        confirmed
      end

      # Claim the pending settle row for `signature` before the broadcast. The
      # cosigner is judged here too, so a key the app does not seat is refused
      # before anything is sent.
      def claim_settle_script(ptx_slug, cosigner, signature)
        <<~RUBY
          tx = PendingTransaction.find_by!(slug: #{ptx_slug.inspect})
          refuse("#{ptx_slug} is a " + tx.tx_type + ", not a settle_contest") unless tx.tx_type == "settle_contest"
          cosigner = #{cosigner.inspect}
          refuse("cosigner " + cosigner + " is not in the multisig set: nothing was sent") unless Solana::Config::MULTISIG_SIGNERS.include?(cosigner)
          refuse("#{ptx_slug} is " + tx.status + ", not pending: nothing was sent") unless tx.claim_for_broadcast!(#{signature.inspect})
          emit(claimed: tx.slug, status: tx.status)
        RUBY
      end

      # What the settle needs beyond the server's own signature.
      def settle_request_script
        <<~RUBY
          vault = Solana::Vault.new
          action = "settle_contest"
          #{cosign_request_ruby(named: 1)}
        RUBY
      end

      # THE CONFIRM, ON THE DYNO. The same checks, in the same order, as
      # Admin::PendingTransactionsController#confirm and
      # #verify_and_record_cosign!, for the one tx_type this driver settles:
      # the row is pending, the cosigner is in the multisig set, the extras pass
      # CosignPlan, and TxVerifier proves each signer and the contest PDA on the
      # landed transaction BEFORE anything is written. A drift between the two
      # is caught by test/lib/qa_rehearsal_unattended_settle_test.rb.
      def confirm_settle_script(ptx_slug, cosigner, extras, signature)
        <<~RUBY
          tx = PendingTransaction.find_by!(slug: #{ptx_slug.inspect})
          refuse("#{ptx_slug} is a " + tx.tx_type + ", not a settle_contest") unless tx.tx_type == "settle_contest"
          claimed = tx.status == "submitted" && tx.tx_signature == #{signature.to_s.inspect}
          refuse("#{ptx_slug} is " + tx.status + ", not claimed for this signature") unless claimed || tx.pending? || tx.awaiting_reconciliation?
          cosigner = #{cosigner.inspect}
          refuse("cosigner " + cosigner + " is not in the multisig set") unless Solana::Config::MULTISIG_SIGNERS.include?(cosigner)
          extras = Solana::CosignPlan.new(tx_type: tx.tx_type).validate_extras!(#{extras.inspect}, primary: cosigner)
          contest = tx.target
          writable = contest.onchain_contest_id.presence ||
                     Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(contest.slug).first)
          signature = #{signature.to_s.inspect}
          Solana::TxVerifier.verify!(signature: signature, instruction_name: "settle_contest",
                                     signer_pubkey: cosigner, writable_pubkey: writable)
          Array(extras).each do |extra|
            Solana::TxVerifier.verify!(signature: signature, instruction_name: "settle_contest",
                                       signer_pubkey: extra, writable_pubkey: nil)
          end
          tx.settlement_contest&.mark_settled!(signature)
          tx.update!(status: "confirmed", cosigner_address: cosigner,
                     cosigner_addresses: [cosigner, *Array(extras)], tx_signature: signature)
          emit(status: tx.status, contest_status: contest.reload.status,
               onchain_settled: contest.onchain_settled, tx_signature: signature)
        RUBY
      end

      # The settle wire naming `cosigner` (and, on v0.26, `extras`). With too
      # few extras for the chain's threshold it answers a cosign request.
      def settle_build_script(slug, cosigner, extras = [])
        <<~RUBY
          contest = Contest.find_by!(slug: #{slug.inspect})
          winners = contest.entries.complete.where("payout_cents > 0").includes(:user).map do |e|
            { wallet: e.user.solana_address, entry_num: e.entry_number || 0, rank: e.rank || 0,
              payout: Solana::Config.cents_to_base_units(e.payout_cents) }
          end.select { |w| w[:wallet].present? }
          vault = Solana::Vault.new
          action = "settle_contest"
          extras = #{extras.inspect}
          needed = Solana::Config.governance? ? vault.required_signatures(action) - 2 : 0
          if extras.size < needed
            #{cosign_request_ruby(named: 2)}
          else
            built = vault.build_settle_contest(
              contest.slug, winners, cosigner_pubkey: #{cosigner.inspect}, extra_cosigners: extras
            )
            emit(serialized_tx: built[:serialized_tx], winners: winners.size)
          end
        RUBY
      end

      # ── v0.26 agent cosigning ──────────────────────────────────────────
      #
      # v0.26 raised lock and close to 2 signatures and settle to 3, and the
      # dyno holds one vault key. Each script first answers what it needs (a
      # cosign request); the driver picks seated agents whose keys it files,
      # asks for a server-signed wire with their slots, and signs here, where
      # the keys are. The thresholds come from the chain, so a retune moves
      # the count without a code change.

      # Ruby, for a remote script that has `vault` and `action` in scope: emit
      # what a v0.26 action needs beyond the `named` signers the dyno fills.
      def cosign_request_ruby(named:)
        "emit(cosign: vault.unattended_cosign_request(action, named: #{named}))"
      end

      # Ruby, for a remote script with `vault` and `action` in scope: with too
      # few cosigners, the request; with enough, the wire `build` returns.
      def cosign_or_build_ruby(cosigners, named:, build:)
        <<~RUBY
          cosigners = #{cosigners.inspect}
          if cosigners.size < vault.required_signatures(action) - #{named}
            #{cosign_request_ruby(named: named)}
          else
            built = #{build}
            emit(serialized_tx: built[:serialized_tx], cosigners: cosigners)
          end
        RUBY
      end

      # The filed agent keys that fill a request: seated in VaultState, not
      # the server's own key, not already signing. Refuses a shortfall by name
      # rather than sending a transaction the chain would reject.
      #
      # A FENCED KEY IS REFUSED, NOT SKIPPED. A filed agent key that is also a
      # mainnet VaultState signer means the roster and the fence disagree, and
      # quietly picking around it would hide that until a run needed the key.
      def pick_agents(request, exclude: [])
        needed = request.fetch("needed").to_i
        seated = Array(request["seated"])
        taken = exclude + [request["server"]]

        candidates = vault_agents.filter_map do |who|
          [who, keys.keypair(who)]
        rescue KeyStore::MissingKeyError
          nil
        end
        refuse_mainnet_signers!(candidates.to_h { |who, kp| [kp.to_base58, who] })

        picked = candidates.map(&:last)
                           .select { |kp| seated.include?(kp.to_base58) && !taken.include?(kp.to_base58) }
                           .first(needed)
        return picked if picked.size == needed

        raise StepError, "#{request['action']} needs #{needed} agent signature(s) beyond the server's on v0.26, " \
                         "and the filed agents (#{vault_agents.join(', ')}) seat #{picked.size} in VaultState. " \
                         "Nothing was sent. Seat an agent key, or run this step through the Treasury cosign."
      end

      def vault_agents
        VAULT_AGENTS
      end

      def mainnet_fence
        @mainnet_fence ||= MainnetSignerFence.default
      end

      # { pubkey => label } — raises StepError naming every fenced key.
      def refuse_mainnet_signers!(labelled)
        mainnet_fence.refuse!(labelled.keys, who: labelled)
      rescue MainnetSignerFence::Refused => e
        raise StepError, e.message
      end

      # Each agent fills its own slot; the last one completes the wire. Sent
      # through Solana::Config.client (fails closed on a missing RPC URL).
      # The fence runs again here: every agent signature passes through this
      # method, whoever picked the key.
      def sign_and_send(answer, signers)
        Solana::Config.client.send_and_confirm(sign_wire(answer, signers))
      end

      # The fully signed wire, every agent slot filled; nothing is sent.
      def sign_wire(answer, signers)
        refuse_mainnet_signers!(signers.to_h { |kp| [kp.to_base58, nil] })
        wire = answer.fetch("serialized_tx")
        signers.each_with_index do |kp, i|
          wire = Solana::Transaction.cosign_wire_base64(wire, signer: kp, require_complete: i == signers.size - 1)
        end
        wire
      end

      # The attended half — the path production actually uses. Mints a signed-in
      # link straight to the Treasury page so the co-signature is two taps.
      def offer_cosign_link(graded)
        link = remote.call(<<~RUBY)
          token = Studio::Link.create_magic_link(
            email: #{COSIGNER_EMAIL.inspect},
            return_to: "/admin/pending_transactions",
            ttl: 12.hours
          ).token
          emit(token: token, cosigner: Solana::Config::MULTISIG_COSIGNER)
        RUBY

        url = "https://#{host}/l/#{link.fetch('token')}"
        say ""
        say "  Magic Link: #{url}"
        say "  Open it on a desktop browser with Phantom on wallet #{link['cosigner']}."
        say "  Press Co-sign on #{graded.fetch('ptx_slug')} and approve in Phantom: the page builds a fresh"
        say "  transaction at the click. It worked when the row reads Confirmed."
        # The one halt that is not a courtesy: this step CANNOT proceed without
        # him. The settle is 2-of-3 and the server has signed only its own half,
        # so an agent that runs `close` next closes a contest that never paid.
        hand_back(verify: "the payout landed — the pool fell by exactly the sum paid, " \
                          "and each winner rose by exactly their rank",
                  next_command: "bin/qa-contest-rehearsal close")
        { magic_link: url, ptx_slug: graded["ptx_slug"] }
      end

      # Every step ends by printing where to LOOK. The operator drives this from a
      # terminal but watches it in a browser, and a step that reports what it did
      # without saying where to see it makes them go hunting for a URL they were
      # just told about in a different step.
      def say_urls(slug, live_first: false)
        contest = "https://#{host}/contests/#{slug}"
        say ""
        if live_first
          say "  Live Board:   #{contest}/live"
          say "  Contest:      #{contest}"
        else
          say "  Contest:      #{contest}"
          say "  Live Board:   #{contest}/live"
        end
        say "  League Board: https://#{host}/live"
      end

      # THE HALT. A step that ends by printing a URL and returning is a step an
      # agent runs straight past — measured 2026-09-04, when a rehearsal ran all
      # five steps in one turn and the operator never saw a board mid-flight.
      #
      # The five-step split exists so the run can be WATCHED. Without a halt the
      # split buys nothing: the same five things happen, and the only person who
      # wanted to look between them is told about it afterwards.
      #
      # This prints where the STOP has to be read — the terminal, at the moment
      # the agent is deciding what to do next. The SOP says the same thing, but
      # prose read once at the top loses to momentum, and a doc that is the ONLY
      # place a rule lives is a doc that drifts.
      #
      # `verify` is what the operator is being asked to confirm, in their words,
      # not a restatement of what the step did. "Entries read 3/29" is checkable
      # at a glance; "entries were created" is not.
      def hand_back(verify:, next_command: nil)
        say ""
        say "  ── STOP ─────────────────────────────────────────────────────"
        say "  Hand the URLs above to Mr. McRitchie and WAIT for his go-ahead."
        say "  Ask him to confirm: #{verify}"
        say "  (An unattended devnet gauntlet checks this itself, records it, and goes on:"
        say "   contest-rehearsal SOP, \"Unattended\".)"
        say ""
        say(next_command ? "  Next, once he confirms:  #{next_command}" : "  This was the last step. The rehearsal is complete.")
        say "  ─────────────────────────────────────────────────────────────"
      end

      def say(message)
        io.puts(message)
      end
    end
  end
end
