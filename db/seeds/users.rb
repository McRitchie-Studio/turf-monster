# Shared core user definitions — used by db/seeds.rb and e2e/seed.rb.
#
# Returns a hash of User objects keyed by username string.
# Adopts existing rows by email, wallet, or username for idempotency.

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
# Every parked identity happens to carry a wallet today, which is exactly why
# this is extracted and tested directly rather than left inline: the roster no
# longer demonstrates the case the guard exists for, and the next identity added
# may not have one.
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

  User.where(username: wanted).find_each do |holder|
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

def seed_core_users!
  users = {}

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
    if username.present? && User.where(username: username).where.not(id: user.id).exists?
      puts "  ! #{data[:email]} wants #{username.inspect}, which is taken — keeping #{user.username.inspect}"
      username = user.username
    end

    # Ensure fields are up to date on existing records
    user.assign_attributes(
      email: data[:email],
      name: data[:name],
      username: username,
      role: data[:role] || "user"
    )

    # Set Phantom wallet address (real wallets, not managed)
    user.assign_attributes(
      web3_solana_address: data[:wallet],
      web2_solana_address: nil,
      encrypted_web2_solana_private_key: nil
    )
    user.save!

    users[data[:username]] = user
  end

  # Backfill managed wallets for users without any wallet
  User.where(web2_solana_address: nil, web3_solana_address: nil).find_each(&:generate_managed_wallet!)

  puts "  Created #{User.count} users"
  users
end
