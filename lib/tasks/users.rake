# Takes the rotated-out wallet (Solana::RotatedOutWallet) off any user row and
# ends that row's live sessions. Idempotent. Prints the count and the usernames
# only, and exits non-zero when a row still holds the wallet.
#
#   bin/rails users:clear_rotated_out_wallet
#
# Two read-only reports for the operator. Neither writes, and neither prints an
# email address.
#
#   bin/rails users:email_case_collisions   # counts only
#   bin/rails users:parked_role_audit       # usernames only
namespace :users do
  desc "Count emails that collide when compared without case (read-only, counts only)"
  task email_case_collisions: :environment do
    colliding = User.where.not(email: nil).group("LOWER(email)").having("COUNT(*) > 1").select("COUNT(*) AS n")
    addresses, rows = User.unscoped.from(colliding, :collisions).pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(n), 0)"))
    unnormalised = User.where("email <> LOWER(BTRIM(email))").count

    puts "users:email_case_collisions — #{addresses} colliding #{addresses == 1 ? 'address' : 'addresses'} across #{rows.to_i} rows"
    puts "  #{unnormalised} #{unnormalised == 1 ? 'row holds' : 'rows hold'} an address that is not stripped and downcased"
    puts addresses.zero? ? "  a unique index on LOWER(email) would build" : "  a unique index on LOWER(email) would fail until these are resolved"
  end

  desc "List usernames holding a parked role on an unverified or inexact email (read-only)"
  task parked_role_audit: :environment do
    roster = User::PARKED_IDENTITIES
    by_email = roster.index_by { |identity| identity[:email] }
    wallets = roster.filter_map { |identity| identity[:wallet].presence }
    label = ->(user) { user.username.presence || "user ##{user.id}" }

    flagged = User.where("LOWER(BTRIM(email)) IN (?)", by_email.keys).order(:id).filter_map do |user|
      identity = by_email.fetch(user.email.strip.downcase)
      next unless user.role == identity[:role]

      reasons = []
      reasons << "email unverified" if user.email_verified_at.blank?
      reasons << "email is not an exact match" unless user.email == identity[:email]
      next if reasons.empty?

      wallet = identity[:wallet].present? && [ user.web3_solana_address, user.web2_solana_address ].include?(identity[:wallet])
      "  #{label.call(user)} — role #{user.role}; #{reasons.join(', ')}; parked wallet #{wallet ? 'matches' : 'does not match'}"
    end

    undescribed = User.where(role: "admin").order(:id).reject do |user|
      by_email.key?(user.email.to_s.strip.downcase) ||
        wallets.intersect?([ user.web3_solana_address, user.web2_solana_address ].compact)
    end

    puts "users:parked_role_audit — #{flagged.size} holding a parked role on an unverified or inexact email"
    puts flagged
    puts "  a seeded row reads unverified until its first email sign-in" if flagged.any?
    puts "#{undescribed.size} admin #{undescribed.size == 1 ? 'row' : 'rows'} matching no parked identity"
    undescribed.each { |user| puts "  #{label.call(user)}" }
  end

  desc "Clear the rotated-out wallet from any user row and end its sessions (idempotent)"
  task clear_rotated_out_wallet: :environment do
    cleared = Solana::RotatedOutWallet.clear_from_users!

    line = "users:clear_rotated_out_wallet — cleared #{cleared.size} #{cleared.size == 1 ? 'user' : 'users'}"
    line += ": #{cleared.join(', ')}" if cleared.any?
    puts line

    abort "users:clear_rotated_out_wallet — a row still holds the wallet" if Solana::RotatedOutWallet.holders.exists?
  end
end
