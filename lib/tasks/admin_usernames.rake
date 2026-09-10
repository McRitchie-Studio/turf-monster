# Kickoff username claims — Track 1 (DB-only, no program changes).
#
# Idempotently claims the parked kickoff usernames in the DB for the rows
# holding the matching wallet addresses (web3_solana_address first — these
# are Phantom-owned wallets — falling back to web2_solana_address).
#
# DB-only by design: Phantom-owned wallets can't be signed server-side, so
# this task NEVER pushes on-chain set_username. After a claim, the on-chain
# UserAccount PDA still holds the old name until the owner signs
# set_username via /account — or, for the house "turf" account, until the
# v0.25 admin path can initialize it (its name is a reserved prefix the
# program rejects from the user path, 6020 UsernameReserved).
#
# Username-taken conflicts are reported, not raised. Failures land in
# ErrorLog (backend discipline #1) and the task keeps going.
#
#   bin/rails admin:claim_usernames            # apply
#   DRY_RUN=1 bin/rails admin:claim_usernames  # report only, no writes
namespace :admin do
  desc "Idempotently claim parked kickoff usernames in the DB by wallet (DRY_RUN=1 to preview)"
  task claim_usernames: :environment do
    # KEYED BY WALLET, so an identity without one has nothing for this task to
    # claim and is skipped rather than fetched. Every parked identity carries a
    # wallet as of 2026-09-04 (the email-only alex@turfmonster.media admin that
    # `fetch` used to raise KeyError on — taking the whole task down — was
    # retired), so keep the guard for the next one that does not.
    kickoff = User::PARKED_IDENTITIES.each_with_object({}) do |identity, claims|
      wallet = identity[:wallet]
      next if wallet.blank?

      claims[wallet] = identity
    end.freeze

    # THE SWAP DEADLOCK. Two kickoff rows can want each other's names — `alex`
    # and `mcritchie` traded owners on 2026-09-04 — and the holder check below
    # then refuses BOTH: each wants a name the other is sitting on. A single
    # pass reports two CONFLICTs, writes nothing, and exits 0, so the swap looks
    # done and never happened.
    #
    # So tell a swap PARTNER from a squatter. A holder that is itself a kickoff
    # row headed somewhere else is parked (username nulled) and picks up its own
    # name later in this same loop. A holder no kickoff wallet owns is a real
    # conflict and still keeps its name: this task never renames a stranger.
    claimed_by = kickoff.each_with_object({}) do |(wallet, identity), map|
      holder = User.find_by(web3_solana_address: wallet) || User.find_by(web2_solana_address: wallet)
      map[holder.id] = identity.fetch(:username) if holder
    end.freeze

    dry_run = ENV["DRY_RUN"].present?
    puts dry_run ? "admin:claim_usernames — DRY RUN (no writes)" : "admin:claim_usernames"
    puts

    onchain_owed = []

    kickoff.each do |wallet, identity|
      username = identity.fetch(:username)
      label = "#{username.ljust(10)} #{wallet[0, 4]}…#{wallet[-4, 4]}"

      user = User.find_by(web3_solana_address: wallet) || User.find_by(web2_solana_address: wallet)
      unless user
        puts "  SKIP    #{label} — no user holds this wallet"
        next
      end

      if user.username&.casecmp?(username)
        changed = false
        changed = user.claim_parked_identity! unless dry_run
        verb = changed ? "CLAIMED" : "OK"
        detail = changed ? "identity fields repaired for #{user.slug}" : "already claimed by #{user.slug}"
        puts "  #{verb.ljust(7)} #{label} — #{detail}"
        onchain_owed << [user, username]
        next
      end

      holder = User.where("LOWER(username) = ?", username.downcase).where.not(id: user.id).first
      swapping = holder && claimed_by.key?(holder.id) && !claimed_by[holder.id].to_s.casecmp?(username)

      if holder && !swapping
        puts "  CONFLICT #{label} — \"#{username}\" is held by #{holder.slug}; #{user.slug} keeps \"#{user.username}\""
        next
      end

      if dry_run
        after = swapping ? " (after #{holder.slug} releases it)" : ""
        puts "  CLAIM   #{label} — would rename #{user.slug}: \"#{user.username}\" -> \"#{username}\"#{after}"
        onchain_owed << [user, username]
        next
      end

      # Park the swap partner so the unique index does not refuse this claim. It
      # is only ever nulled here, never handed to anyone: the partner claims its
      # own parked name on its own pass through this loop.
      holder.update_column(:username, nil) if swapping

      begin
        previous = user.username
        user.claim_parked_identity!
        puts "  CLAIMED #{label} — #{user.slug}: \"#{previous}\" -> \"#{username}\""
        onchain_owed << [user, username]
      rescue StandardError => e
        # Report-don't-raise: log to ErrorLog (the durable trace) and move on
        # so one bad row doesn't strand the remaining claims.
        ErrorLog.create!(
          message: "admin:claim_usernames failed for #{wallet}: #{e.class}: #{e.message}",
          inspect: { wallet: wallet, username: username, user: user.slug }.to_json,
          backtrace: Array(e.backtrace).first(10).to_json,
          target: user,
          target_name: user.slug
        )
        puts "  ERROR   #{label} — #{e.class}: #{e.message} (logged to ErrorLog)"
      end
    end

    puts
    puts "On-chain set_username still owed (DB-only task — chain state not checked):"
    if onchain_owed.empty?
      puts "  none"
    else
      onchain_owed.each do |user, username|
        path = user == User.turf ? "v0.25 admin init path (reserved name — program rejects the user path)" : "owner signs via /account"
        puts "  #{username.ljust(10)} #{user.slug} — #{path}"
      end
    end
  end
end
