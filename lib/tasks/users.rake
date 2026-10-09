# Takes the rotated-out wallet (Solana::RotatedOutWallet) off any user row and
# ends that row's live sessions. Idempotent. Prints the count and the usernames
# only, and exits non-zero when a row still holds the wallet.
#
#   bin/rails users:clear_rotated_out_wallet
namespace :users do
  desc "Clear the rotated-out wallet from any user row and end its sessions (idempotent)"
  task clear_rotated_out_wallet: :environment do
    cleared = Solana::RotatedOutWallet.clear_from_users!

    line = "users:clear_rotated_out_wallet — cleared #{cleared.size} #{cleared.size == 1 ? 'user' : 'users'}"
    line += ": #{cleared.join(', ')}" if cleared.any?
    puts line

    abort "users:clear_rotated_out_wallet — a row still holds the wallet" if Solana::RotatedOutWallet.holders.exists?
  end
end
