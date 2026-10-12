# Moves EXISTING open NFL contests onto the opening-Sunday lock (Contest::LockRule),
# on chain first and then in `contests.starts_at`. The new rule reaches every
# contest created after it ships through ContestsController#default_start_for_slate;
# this is the one-off for the contests already created with the old default, the
# slate's first kickoff — a Thursday when the week opens on TNF.
#
# DRY RUN BY DEFAULT. Nothing is written unless `write: true`
# (`WRITE=1 bin/rails contests:nfl_sunday_lock`). Idempotent: a contest already
# at its new lock on chain and in the DB reads `noop`.
#
# WHAT IT REFUSES, contest by contest, and why:
#
#   * a lock that has ALREADY PASSED, on chain or in the DB. Moving it later
#     would re-open entries after games were played. Never.
#   * a new lock that is not in the future. The same thing seen from the other
#     side, and a lock in the past is also one the program would treat as shut.
#   * a new lock EARLIER than the current one. This exists to push Thursday locks
#     out to Sunday, never to pull one in under people.
#   * a CUSTOM lock: any current lock other than the old default (the slate's
#     first kickoff). Somebody chose it on purpose; this does not overrule them.
#   * no scheduled lock at all (chain lock_timestamp 0 — manual-only).
#   * a chain it cannot read. Fail closed: the chain is the lock that counts.
#   * a concluded, cancelled, settled or not-yet-verified contest.
#
# THE SIGNING PATH. On-chain contests move through Solana::Vault#set_contest_lock_time,
# the server-signed (admin key) path kept for unattended callers. Its comment says
# why no HUMAN-facing route may call it: one always-online key could extend a live
# window. This is an operator-run one-off whose every move is printed in a dry run
# first and is bounded by the guards above (future locks only, old default only,
# later only).
#
# UNDER turf-vault GOVERNANCE (v0.26) the move needs SET_CONTEST_LOCK_TIME vault
# signatures (2 by default, read from GovernanceConfig) and the admin key is one.
# `cosigners:` are the other vault signers' keypairs, passed to the vault as
# `extra_signers:`; each signs here and rides as a leading remaining account,
# which is what `authorize` reads. The rake task loads them from
# SOLANA_COSIGNER_KEYS (comma-separated base58 secrets, Solana::Keypair.cosigners),
# a window-only config var Steffon sets for the run and unsets after, and prints
# only their public keys. With too few, the vault raises ThresholdUnreachableError
# BEFORE broadcasting; the dry run already says how many the move needs and how
# many the run holds, and the operator can move that contest with Phantom instead
# — the contest edit page's lock picker (prepare_lock_time / confirm_lock_time),
# where the server key is the second signer, with the timestamp the dry run prints.
module Contests
  class ApplyNflSundayLock
    Row = Struct.new(:slug, :action, :current_lock, :new_lock, :reason, keyword_init: true)

    def initialize(write: false, now: Time.current, slugs: nil, vault: nil, out: $stdout, cosigners: [])
      @write = write
      @cosigners = Array(cosigners).compact
      @now = now
      @slugs = Array(slugs).map(&:to_s).reject(&:blank?)
      @vault = vault
      @out = out
    end

    def call
      rows = candidates.map { |contest| process(contest) }
      report(rows)
      rows
    end

    def candidates
      scope = Contest.where(status: :open).includes(:slate).order(:id)
      scope = scope.where(slug: @slugs) if @slugs.any?
      scope.select { |contest| contest.turf_totals? && contest.slate&.sport == "nfl" }
    end

    private

    def process(contest)
      row = plan(contest)
      return row unless @write && %i[move mirror_db].include?(row.action)

      apply(contest, row)
    rescue StandardError => e
      ErrorLog.capture!(e) # a money-path write failure must be findable, not just printed
      Row.new(slug: contest.slug, action: :error, reason: "#{e.class}: #{e.message.to_s[0, 200]}")
    end

    def plan(contest)
      row = Row.new(slug: contest.slug)
      new_lock = contest.slate.default_contest_lock_at
      old_default = contest.first_kickoff_at
      row.new_lock = new_lock

      return row.tap { finish(row, :refuse, "cancelled") } if contest.onchain? && contest.cancelled?
      return row.tap { finish(row, :refuse, "concluded") } if contest.concluded?
      return row.tap { finish(row, :refuse, "not verified on chain (pending)") } if contest.pending?
      return row.tap { finish(row, :skip, "slate has no kickoff to derive a lock from") } unless new_lock && old_default

      db_lock = contest.locks_at
      chain_lock = contest.onchain_verified? ? chain_lock_for(contest) : db_lock
      return row.tap { finish(row, :refuse, "chain unreadable — fail closed") } if chain_lock == :unreadable

      row.current_lock = chain_lock
      return row.tap { finish(row, :skip, "no scheduled lock (manual-only)") } if chain_lock.nil?
      return row.tap { finish(row, :refuse, "current lock already passed") } if chain_lock <= @now
      return row.tap { finish(row, :refuse, "DB lock already passed") } if db_lock && db_lock <= @now

      if chain_lock.to_i == new_lock.to_i
        return row.tap { finish(row, :noop, "already at the new lock") } if db_lock&.to_i == new_lock.to_i

        return row.tap { finish(row, :mirror_db, "chain already moved; DB still #{fmt(db_lock)}") }
      end

      return row.tap { finish(row, :refuse, "new lock is not in the future") } if new_lock <= @now
      return row.tap { finish(row, :refuse, "new lock is earlier than the current lock") } if new_lock < chain_lock
      return row.tap { finish(row, :skip, "custom lock (not the old first-kickoff default)") } unless chain_lock.to_i == old_default.to_i

      finish(row, :move, "first kickoff #{fmt(old_default)} -> opening Sunday#{signature_note(contest)}")
      row
    end

    # v0.26 only: how many vault signatures this move needs (the chain's own
    # threshold for the action the contest's state selects) against how many
    # this run holds, so the dry run says before WRITE=1 whether it can land.
    # Empty on v0.25, where the admin key alone moves a lock.
    def signature_note(contest)
      return "" unless Solana::Config.governance? && contest.onchain_verified?

      action = vault.governed_time_action("set_contest_lock_time", contest.slug)
      needed = vault.required_signatures(action)
      held = 1 + @cosigners.map(&:to_base58).uniq.size
      short = held < needed ? " — SHORT: set SOLANA_COSIGNER_KEYS or use the lock picker" : ""
      "; v0.26 #{action} needs #{needed} signature(s), this run holds #{held}#{short}"
    rescue StandardError => e
      "; v0.26 signature count unreadable (#{e.class})"
    end

    def apply(contest, row)
      if row.action == :move && contest.onchain_verified?
        vault.set_contest_lock_time(contest.slug, row.new_lock.to_i, extra_signers: @cosigners)
        landed = chain_lock_for(contest)
        unless landed != :unreadable && landed&.to_i == row.new_lock.to_i
          return finish(row, :error, "chain did not confirm the new lock (reads #{landed.inspect}); DB left at the old lock")
        end
      end

      contest.update!(starts_at: Time.zone.at(row.new_lock.to_i))
      finish(row, row.action == :move ? :moved : :mirrored, row.reason)
    end

    # The chain's lock as a Time, nil for 0 (no scheduled lock), or :unreadable.
    def chain_lock_for(contest)
      onchain = vault.read_contest(contest.slug)
      return :unreadable unless onchain

      ts = onchain[:lock_timestamp].to_i
      ts.zero? ? nil : Time.zone.at(ts)
    rescue StandardError => e
      Rails.logger.warn("[contests:nfl_sunday_lock] read_contest #{contest.slug} failed: #{e.class}: #{e.message.to_s[0, 140]}")
      :unreadable
    end

    def vault
      @vault ||= Solana::Vault.new
    end

    def finish(row, action, reason)
      row.action = action
      row.reason = reason
      row
    end

    def report(rows)
      @out.puts(@write ? "WRITE — moving locks" : "DRY RUN — nothing written (WRITE=1 to apply)")
      @out.puts("now #{fmt(@now)}; #{rows.size} open NFL contest(s)")
      @out.puts("cosigners: #{@cosigners.map(&:to_base58).join(', ')}") if @cosigners.any?
      rows.each do |row|
        @out.puts(format("  %-10s %-48s current %-24s new %-24s (unix %s) %s",
                         row.action, row.slug, fmt(row.current_lock), fmt(row.new_lock),
                         row.new_lock&.to_i || "-", row.reason))
      end
    end

    def fmt(time)
      return "-" unless time

      time.in_time_zone(Contest::LockRule::ZONE).strftime("%a %Y-%m-%d %H:%M %Z")
    end
  end
end
