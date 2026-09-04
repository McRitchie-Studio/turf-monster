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
      ADMIN_ACTOR = "turf"

      # Mason and Mack, and the two exclusions are not preferences:
      #
      #   * ALEX cannot play. `agent.alex.solana` IS the Alex Bot wallet — the
      #     fee payer and contest creator. When the player is also the fee
      #     payer the transaction needs one signature slot, not two, and
      #     prepare_entry refuses with "Signer count mismatch: 2 provided
      #     (0 local + 2 additional), 1 required by the account list".
      #   * TURF cannot play. Its username is literally "turf", a reserved
      #     on-chain prefix, and it has no UserAccount yet. The program (v0.25)
      #     ships `admin_create_user_account` for exactly this, but
      #     Solana::Vault has no binding for it — so the reserved-name path the
      #     User model's comment promises cannot actually be taken. Bind it and
      #     Turf joins the cast by adding one word to --cast.
      DEFAULT_CAST = %w[mason mack].freeze

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
          # units on-chain. Comparing the two directly is how a $500 pool turns
          # into a 50-cent mint, so convert once and compare in one unit.
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
      def play_preseason(reset: true)
        guard!
        data = manifest.read
        say "Step 3 · run the preseason for #{data['contest_slug']}"

        if reset
          shift = data["kickoff_shift_seconds"].to_i

          cleared = remote.call(<<~RUBY)
            slate = Slate.find_by!(name: #{SLATE_NAME.inspect})
            slugs = slate.slate_matchups.pluck(:game_slug).compact.uniq

            # Undo step 1's time-shift FIRST. The poller matches ESPN by the
            # slot and the game's external id, never by our clock, so this is
            # cosmetic to the fetch -- but a board showing tomorrow's date beside
            # a final score is the kind of detail that makes an operator distrust
            # a run that is actually fine.
            shift = #{shift}
            if shift.positive?
              Game.where(slug: slugs).find_each do |g|
                g.update_columns(kickoff_at: g.kickoff_at - shift.seconds) if g.kickoff_at
              end
            end

            goals = Goal.where(game_slug: slugs).delete_all
            games = Game.where(slug: slugs).update_all(home_score: nil, away_score: nil,
                                                       status: "scheduled", status_detail: nil)
            ms = slate.slate_matchups.update_all(goals: nil, status: "pending")
            emit(goals_deleted: goals, games_reset: games, matchups_reset: ms, unshifted: shift)
          RUBY
          say "  reset: #{cleared['goals_deleted']} goals, #{cleared['games_reset']} games, " \
              "#{cleared['matchups_reset']} matchups back to kickoff"
        end

        say "  watch: https://#{host}/live"
        say "  polling ESPN slot #{POLL_SLOT} …"
        system("heroku", "run", "--app", app, "--no-tty", "--",
               "bin/nfl-live-poll", "--slot", POLL_SLOT)
      end

      # --- Step 4 --------------------------------------------------------
      # Lock, grade, and settle.
      #
      # grade! refuses while the contest is unlocked (the program rejects a
      # settle before lock, so grading first would only fail later and louder),
      # which is why the lock is moved here rather than at create time — the
      # cast needs an open contest in step 2.
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
            contest.update!(onchain_closed: true)
            out[:signature] = sig.is_a?(Hash) ? sig[:signature] : sig
          end
          emit(**out)
        RUBY

        say "  closed: #{result.inspect}"
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

      def say(message)
        io.puts(message)
      end
    end
  end
end
