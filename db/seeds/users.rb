# Shared core user definitions — used by db/seeds.rb, e2e/seed.rb and the QA
# rehearsal's seed step (lib/turf_monster/qa_rehearsal/driver.rb).
#
# Returns a hash of User objects keyed by username string.
# Adopts existing rows by email, wallet, or username for idempotency; the
# rehearsal's seed step adopts only a row it can prove (seed_adoption_refusal).

CORE_USERS = User::PARKED_IDENTITIES.map(&:dup).freeze

# EACH LOOKUP GUARDED ON PRESENCE, and that is the whole point of this method.
#
# `find_by(web3_solana_address: nil)` does not mean "no match" — it matches the
# FIRST user who happens to have no wallet. An identity carrying no wallet would
# therefore ADOPT a stranger's row, and the caller below overwrites email, name,
# username and role on whatever comes back, while nulling
# `encrypted_web2_solana_private_key` on an account whose USDC stays on-chain.
# The same trap sits on `username`.
#
# The house account parks no wallet, so the roster exercises this guard on every
# run. It is extracted so the guard is tested directly.
def find_seed_user(data)
  User.find_by(email: data[:email]) ||
    (data[:wallet].present? ? User.find_by(web3_solana_address: data[:wallet]) : nil) ||
    (data[:username].present? ? User.find_by(username: data[:username]) : nil) ||
    User.new(email: data[:email])
end

# THE SWAP. On 2026-09-04 `alex` and `mcritchie` traded owners, and a swap does
# not fit through a row-at-a-time save: seeding alex@mcritchie.studio first asks
# for a username the team@ row still holds, and the unique index refuses it. A
# FRESH database never sees this — every row is created in order, holding
# nothing — so it is precisely the break that passes locally and then fails on
# the one database that has people in it.
#
# So park first, assign second. Only rows a parked identity actually OWNS are
# parked: a stranger holding a wanted username keeps it, because taking it would
# rename a real account out from under someone to satisfy a seed.
def park_swapped_usernames!(identities)
  wanted = identities.filter_map { |data| data[:username].presence }
  return if wanted.empty?

  intended = identities.each_with_object({}) do |data, map|
    user = find_seed_user(data)
    map[user.id] = data[:username] if user.persisted?
  end

  # LOWER(...), not an exact match: the unique index is on lower(username) and the
  # model validates case-insensitively, so a holder on "Alex" slips past an exact
  # comparison and then trips save! below with exactly the opaque RecordInvalid
  # this guard exists to prevent. lib/tasks/admin_usernames.rake keys the same way.
  User.where("LOWER(username) IN (?)", wanted.map(&:downcase)).find_each do |holder|
    next if intended[holder.id].to_s.casecmp?(holder.username.to_s)

    unless intended.key?(holder.id)
      puts "  ! username #{holder.username.inspect} belongs to user ##{holder.id}, which no parked identity owns — leaving it"
      next
    end

    # update_column: this is a transient park, undone by the assign pass a few
    # lines below. A full save would re-run Sluggable and re-point the row's URL
    # twice for no reason.
    holder.update_column(:username, nil)
  end
end

# A seat the roster RETIRED keeps everything it had, because nothing in this app
# reconciles a row against PARKED_IDENTITIES — dropping an identity from the list
# stops it being described, it does not demote it. So retire it explicitly, and
# only its ROLE: the row may be a real account with entries and a wallet, and a
# seed does not get to delete one of those. Deployed rows are carried by the
# ReconcileTurfParkedIdentities migration; this is the same move for the
# databases a re-seed owns.
def retire_unparked_identities!(retired = User::RETIRED_IDENTITIES)
  retired.each do |email, role|
    # Case-insensitive for the same reason the migration uses LOWER(email): the
    # address is the key here, and its casing is whatever a sign-up once typed.
    row = User.where("LOWER(email) = ?", email.downcase).first
    next if row.nil? || row.role == role

    # update_column: this touches a row the roster no longer describes, so it must
    # not drag a grandfathered record through today's validations to change a role.
    row.update_column(:role, role)
    puts "  ↪ retired #{email}: role -> #{role}"
  end
end

# Raised by seed_parked_identities!(proven_only: true) before any write.
class SeedAdoptionRefused < StandardError; end unless defined?(SeedAdoptionRefused)

# Why a database that already holds people may not hand `data` the row
# find_seed_user returns, or nil when it may. The rule is the mailbox proof's
# (User#accept_mailbox_proof!, docs/AUTH.md "Parked roles"): a row is adopted
# when it is new, holds the identity's wallet, or holds the address verified or
# with no other credential. Rows are named by username, never by address.
def seed_adoption_refusal(data)
  user = find_seed_user(data)
  return nil unless user.persisted?
  return nil if data[:wallet].present? && user.web3_solana_address == data[:wallet]

  label = user.username.presence || "user ##{user.id}"
  unless user.email_matches?(data[:email])
    return "#{label} holds only the username parked for #{data[:username]}, with no row on that identity's address or wallet"
  end
  return nil unless user.unproven_parked_holder? && user.credential_beside_email?

  "#{label} holds the address parked for #{data[:username]} unverified beside another credential (a wallet, a Google link or an API key)"
end

def refuse_unproven_adoptions!(identities)
  reasons = identities.filter_map { |data| seed_adoption_refusal(data) }
  return if reasons.empty?

  raise SeedAdoptionRefused,
        "the roster seed would adopt #{reasons.size == 1 ? 'a row' : "#{reasons.size} rows"} it cannot prove: " \
        "#{reasons.join('; ')}. Nothing was written. An operator resolves each in the database by hand " \
        "(clear the other credential or the address; rename the username holder), then the seed runs again. " \
        "bin/rails users:parked_role_audit lists unproven holders."
end

# The roster rows and the retired seats. No other row is written.
#
# proven_only: for a database that already holds people (the QA rehearsal's
# seed step). It refuses, before any write, a row the mailbox proof would not
# elevate, and ends the sessions of an unproven holder it gives a role or wallet. A fresh
# database holds no row to adopt, so db/seeds.rb and e2e/seed.rb do not pass it.
def seed_parked_identities!(proven_only: false)
  users = {}

  refuse_unproven_adoptions!(CORE_USERS) if proven_only
  retire_unparked_identities!
  park_swapped_usernames!(CORE_USERS)

  CORE_USERS.each do |data|
    # Passwordless (Lazarus audit #4): no password is set — email auth is
    # magic-link only. has_secure_password was removed, so `u.password=` no
    # longer exists; the password_digest column is dormant.
    user = find_seed_user(data)

    # A username still held by a row this seed does not own is REPORTED, not
    # forced. Letting save! raise here would take the whole seed down with an
    # opaque RecordInvalid on a database that is otherwise fine.
    username = data[:username]
    if username.present? &&
       User.where("LOWER(username) = ?", username.downcase).where.not(id: user.id).exists?
      puts "  ! #{data[:email]} wants #{username.inspect}, which is taken — keeping #{user.username.inspect}"
      username = user.username
    end

    # The roster is the seed's authority: a parked address saves here without a
    # mailbox proof, and stays unverified until its first email sign-in.
    user.seeding_parked_identity = true
    unproven = proven_only && user.persisted? && user.unproven_parked_holder?

    # Ensure fields are up to date on existing records
    user.assign_attributes(
      email: data[:email],
      name: data[:name],
      username: username,
      role: data[:role] || "user"
    )

    # Set the Phantom wallet (real wallets, not managed). An identity that parks
    # none has its wallet cleared: that is how a re-seed revokes one.
    user.assign_attributes(
      web3_solana_address: data[:wallet],
      web2_solana_address: nil,
      encrypted_web2_solana_private_key: nil
    )
    # A session opened on an unproven row does not ride into a role or wallet.
    user.regenerate_session_token! if unproven && (user.role_changed? || user.web3_solana_address_changed?)
    user.save!

    users[data[:username]] = user
  end

  users
end

def seed_core_users!
  users = seed_parked_identities!

  # Backfill managed wallets for users without any wallet
  User.where(web2_solana_address: nil, web3_solana_address: nil).find_each(&:generate_managed_wallet!)

  puts "  Created #{User.count} users"
  users
end
