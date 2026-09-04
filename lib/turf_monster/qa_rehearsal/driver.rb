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
      SLATE_NAME = "NFL 2026 Preseason Week 4"
      POLL_SLOT  = "2026:1:4"

      # Standard tier, matching production's world-cup-turf-totals-week-1: five
      # paid ranks over a $500 pool. With a small cast every player finishes in
      # the money, which is the point — it puts the maximum number of winner
      # accounts into the settle transaction the cast can buy.
      CONTEST_TYPE = "standard"
      MAX_ENTRIES  = 29
      ENTRY_FEE_CENTS = 1_900

      # The admin drives the HTTP admin surface. turf-5 is an admin account with
      # a filed key, so the driver can hold its session. It cannot PLAY —
      # its username is the reserved prefix "turf" and the program refuses to
      # register that UserAccount — but admin actions never touch a UserAccount.
      ADMIN_ACTOR = "turf-admin"

      # Mason and Mack, and the two exclusions are not preferences:
      #
      #   * ALEX cannot play. `agent.alex.solana` IS the Alex Bot wallet — the
      #     fee payer and contest creator. When the player is also the fee
      #     payer the transaction needs one signature slot, not two, and
      #     prepare_entry refuses with "Signer count mismatch: 2 provided
      #     (0 local + 2 additional), 1 required by the account list".
      #   * TURF plays as the phantom.turf wallet (39QTL1dd), NOT as the
      #     turf-5 admin account. turf-5's username is the reserved prefix
      #     "turf" and it has no UserAccount, so the program refuses to
      #     register it; phantom.turf already has one, which sidesteps the
      #     whole question. turf-5 stays on as ADMIN_ACTOR, where no
      #     UserAccount is needed.
      DEFAULT_CAST = %w[mason mack turf].freeze

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

      def keys
        @keys ||= begin
          guard!
          KeyStore.new
        end
      end

      def remote
        @remote ||= RemoteRunner.new(app: app)
      end

      def manifest
        @manifest ||= Manifest.new
      end

      # --- Step 1 --------------------------------------------------------
      # Create the contest, funding its prize pool from the admin wallet.
      #
      # Uses the server-funded path (Contest#create_onchain! via after_create)
      # rather than the Phantom create flow. That is a deliberate narrowing: the
      # browser create path is already exercised in production and by the e2e
      # suite, while the steps this rehearsal exists for — entry, grade, settle,
      # payout — are the ones nothing routinely covers.
      def create_contest
        guard!
        say "Step 1 · create contest on #{app} (#{CONTEST_TYPE} tier)"

        result = remote.call(<<~RUBY)
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          vault = Solana::Vault.new

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
          admin = Solana::Keypair.admin.to_base58

          # The prize pool is transferred from the admin wallet at create time,
          # so top it up first. Admin holds mint authority on the devnet test
          # mint, which is why this is free here and impossible on mainnet.
          vault.ensure_ata(admin, mint: Solana::Config::USDC_MINT)

          # The pool is denominated in CENTS in Rails and in 6-decimal base
          # units on-chain. Comparing the two directly is how a 500-dollar pool
          # turns into a 50-cent mint, so convert once and compare in one unit.
          needed_cents = Contest::FORMATS.fetch(#{CONTEST_TYPE.inspect})[:payouts].values.sum
          needed = Solana::Config.dollars_to_lamports(needed_cents / 100.0)
          ata, = Solana::SplToken.find_associated_token_address(admin, Solana::Config::USDC_MINT)
          ata_b58 = Solana::Keypair.encode_base58(ata)
          have = (Solana::Config.client.get_token_account_balance(ata_b58)["value"]["amount"].to_i rescue 0)
          minted = nil
          if have < needed
            minted = vault.mint_spl(needed * 4, mint: Solana::Config::USDC_MINT, to: admin)[:signature]

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

          contest = Contest.create!(
            name: "QA Rehearsal " + Time.current.strftime("%b %-d %H:%M"),
            slate: slate,
            contest_type: #{CONTEST_TYPE.inspect},
            status: "open",
            max_entries: #{MAX_ENTRIES},
            entry_fee_cents: #{ENTRY_FEE_CENTS},
            starts_at: 8.hours.from_now,
            user: User.find_by(slug: "alex-2") || User.where(role: "admin").first
          )

          emit(
            contest_slug: contest.slug,
            name: contest.name,
            onchain: contest.onchain?,
            picks_required: contest.picks_required,
            payouts: contest.payouts,
            prize_pool_cents: contest.guaranteed_prize_cents,
            matchup_ids: contest.matchups.order(:id).pluck(:id),
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
      def play_preseason(reset: true, pace: 0)
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
        if pace.positive? && slate_already_scored?
          say "  slate already holds its real plays — skipping the fetch and replaying from a clean board"

          # UNSHIFT ON THIS PATH TOO. Step 1 nudges the whole week into the
          # future so the board is pickable; putting the clock back used to live
          # inside the `if reset` block below, which this return jumps over. So
          # every paced re-run left the fixture claiming to kick off tomorrow
          # while its games read FINAL — the exact incoherence the unshift
          # exists to prevent, on the path an operator uses most.
          unshift_fixture(data["kickoff_shift_seconds"].to_i)
          return replay(pace)
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
        say "  polling ESPN slot #{POLL_SLOT} …"
        # The return value IS the verdict. A poll that fails exits this method
        # having ALREADY cleared the board, so a later `conclude` would grade an
        # unplayed slate and broadcast a real settle against it.
        unless system("heroku", "run", "--app", app, "--no-tty", "--",
                      "bin/nfl-live-poll", "--slot", POLL_SLOT)
          raise StepError, "the ESPN poll failed — the board is CLEARED and no scores landed. " \
                           "Re-run step 3 before concluding."
        end

        replay(pace) if pace.positive?
      end

      # Replay the week one scoring play at a time, so an operator can watch
      # the board move instead of reading a log of 145 things that already
      # happened.
      #
      # This is a REPLAY, not a simulation. The poll above has already written
      # the real Goal rows; this captures them, deletes them, and writes them
      # back one at a time. Every re-created Goal fires the same callbacks the
      # feed fires — refresh_game_scores, the contest re-score, and BOTH live
      # broadcasts — so what appears on /live is the real touchdown, arriving
      # on a clock we choose.
      #
      # It runs entirely on the dyno, in ONE invocation, and streams. A version
      # that reached back to Rails per play would cost a dyno per touchdown.
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
        locked = remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          unless contest.locked?
            Solana::Vault.new.set_contest_lock_time(contest.slug, Time.current.to_i)
            contest.update!(starts_at: Time.current)
          end
          emit(locked: contest.reload.locked?, live: contest.live?)
        RUBY
        say "  contest locked: #{locked['locked']} · live page: #{locked['live'] ? 'open' : 'closed'}"
      end

      def replay(pace)
        say ""
        say "  replaying #{POLL_SLOT} at #{pace}s per scoring play — watch https://#{host}/live"

        script = <<~RUBY
          slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
          slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq
          kickoffs = Game.where(slug: slugs).pluck(:slug, :kickoff_at).to_h

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
          puts "replay: board cleared, \#{captured.size} plays queued, \#{zeroed} score(s) zeroed"
          STDOUT.flush

          remaining = captured.group_by { |g| g["game_slug"] }.transform_values(&:size)

          captured.each_with_index do |attrs, i|
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

            sleep #{pace}
          end

          puts "replay: done — \#{captured.size} plays, \#{remaining.size} games"
        RUBY

        # The streaming path bypasses RemoteRunner, so it borrows its guard
        # rather than rediscovering the shell-expansion bug on its own.
        if script.match?(RemoteRunner::SHELL_EXPANDABLE)
          raise StepError, "replay script contains a shell-expandable name — see RemoteRunner::SHELL_EXPANDABLE"
        end

        return if system("heroku", "run", "--app", app, "--no-tty", "--", "bin/rails", "runner", script)

        raise StepError, "the replay failed partway — the board holds a partial week. Re-run step 3."
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
        guard!
        data = manifest.read
        slug = data.fetch("contest_slug")
        say "Step 4 · conclude #{slug}"

        graded = remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          vault = Solana::Vault.new

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
          contest.grade! unless contest.settled?
          contest.reload
          ptx = PendingTransaction.where(target: contest, tx_type: "settle_contest").order(:id).last
          winners = contest.entries.complete.where("payout_cents > 0").order(:rank).map do |e|
            { entry: e.id, user: e.user&.slug, rank: e.rank, payout_cents: e.payout_cents,
              wallet: e.user&.solana_address }
          end

          emit(status: contest.status, onchain_settled: contest.onchain_settled,
               ptx_slug: ptx&.slug, ptx_status: ptx&.status, winners: winners)
        RUBY

        say "  graded: #{graded['status']} · #{graded['winners'].size} winner(s)"
        graded["winners"].each do |w|
          say "    ##{w['rank']} #{w['user']} $#{w['payout_cents'].to_i / 100} (#{w['wallet'].to_s[0, 8]}…)"
        end

        manifest.merge("ptx_slug" => graded["ptx_slug"], "winners" => graded["winners"])

        say_urls(slug)

        return say("  no settle transaction to co-sign (nobody was owed)") if graded["ptx_slug"].blank?

        cosign == :link ? offer_cosign_link(graded) : cosign_with_agent(graded)
      end

      # --- Step 5 --------------------------------------------------------
      def close_contest
        guard!
        data = manifest.read
        slug = data.fetch("contest_slug")
        say "Step 5 · reclaim rent on #{slug}"

        result = remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          out = { already_closed: contest.onchain_closed }
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
        RUBY

        say "  closed: #{result.inspect}"
        say_urls(slug)
        result
      end

      private

      # The unattended half. Mason is the second signer on the vault, the server
      # already signed as Alex Bot when it built the transaction, and 2-of-3 is
      # satisfied without a browser. Everything the server does afterwards —
      # TxVerifier, the onchain_settled flip, the winner emails — is unchanged.
      def cosign_with_agent(graded)
        slug = manifest.read.fetch("contest_slug")
        say "  co-signing as mason (agent key)"

        mason = keys.keypair("mason")

        # The stored PendingTransaction reserves a signature slot for whoever
        # Solana::Config::MULTISIG_COSIGNER names -- by default Mr. McRitchie's
        # Phantom. Mason is a valid vault signer but he is not in THAT
        # transaction's account list, so signing it fails with "not a required
        # signer". The unattended path therefore builds its own wire naming
        # Mason, and leaves the stored one alone for the browser path to use.
        wire = remote.call(<<~RUBY)
          contest = Contest.find_by!(slug: #{slug.inspect})
          winners = contest.entries.complete.where("payout_cents > 0").includes(:user).map do |e|
            { wallet: e.user.solana_address, entry_num: e.entry_number || 0, rank: e.rank || 0,
              payout: Solana::Config.dollars_to_lamports(e.payout_cents / 100.0) }
          end.select { |w| w[:wallet].present? }
          built = Solana::Vault.new.build_settle_contest(
            contest.slug, winners, cosigner_pubkey: #{mason.to_base58.inspect}
          )
          emit(serialized_tx: built[:serialized_tx], winners: winners.size)
        RUBY
        signed = Solana::Transaction.cosign_wire_base64(wire.fetch("serialized_tx"), signer: mason)
        # Solana::Config.client, never Solana::Client.new: a raw client falls
        # through to the gem's ENV.fetch("SOLANA_RPC_URL", <public devnet>) and
        # so FAILS OPEN, where Solana::Config::RPC_URL fails closed (OPSEC-012).
        # The repo has a test that enforces exactly this, and it caught this
        # line in CI.
        signature = Solana::Config.client.send_and_confirm(signed)
        say "  broadcast: #{signature}"

        response = admin_session.post_json(
          "/admin/pending_transactions/#{graded.fetch('ptx_slug')}/confirm",
          cosigner_address: mason.to_base58,
          tx_signature: signature
        )

        raise StepError, "confirm refused: #{response['error']}" if response["error"].present?

        say "  confirmed: #{response.inspect}"
        response
      end

      # The attended half — the path production actually uses. Mints a signed-in
      # link straight to the Treasury page so the co-signature is two taps.
      def offer_cosign_link(graded)
        link = remote.call(<<~RUBY)
          token = Studio::Link.create_magic_link(
            email: "alex@mcritchie.studio",
            return_to: "/admin/pending_transactions",
            ttl: 12.hours
          ).token
          emit(token: token)
        RUBY

        url = "https://#{host}/l/#{link.fetch('token')}"
        say ""
        say "  Magic Link: #{url}"
        say "  Rebuild, then Co-sign in Phantom. Transaction #{graded.fetch('ptx_slug')} is waiting."
        { magic_link: url, ptx_slug: graded["ptx_slug"] }
      end

      def admin_session
        @admin_session ||= begin
          session = WalletSession.new(host: host, keypair: keys.keypair(ADMIN_ACTOR))
          session.sign_in!
          session
        end
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

      def say(message)
        io.puts(message)
      end
    end
  end
end
