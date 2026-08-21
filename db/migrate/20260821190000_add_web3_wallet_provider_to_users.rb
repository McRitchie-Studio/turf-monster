# Remember WHICH wallet a web3 user authenticated with, and when.
#
# The step-up modal (Web3StepUpPolicy) exists to tell a wallet-secured account
# that its email/Google session cannot sign on-chain. A generic "connect a
# wallet" picker makes that user re-choose from three brands they already chose
# once; leading with the brand they actually used turns the step into one click.
#
# web3_wallet_provider is a BRAND name normalised through
# Solana::WalletProvider (phantom / solflare / backpack), never free text from
# the client — an unknown name stores nil and the modal falls back to the
# picker. web3_authenticated_at is the last time a signature proved that wallet,
# which is what makes a stale provider legible instead of merely old.
#
# Both are nullable and backfill-free ON PURPOSE: every account that linked a
# wallet before this deploy has a web3_solana_address and no provider, and the
# modal already handles that (it opens the picker). A backfill would have to
# GUESS the brand from an address, which is not recoverable information.
class AddWeb3WalletProviderToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :web3_wallet_provider, :string
    add_column :users, :web3_authenticated_at, :datetime
  end
end
