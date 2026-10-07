# The wallet that entered each entry: the one whose seeds derive its on-chain
# ContestEntry PDA, and so the one Contest#settle_onchain! must pay. Nullable:
# off-chain and never-funded entries have none, and an on-chain entry whose
# wallet cannot be proven stays nil so grading refuses instead of guessing.
# Existing rows are filled by `bin/rails entries:backfill_wallet_address`.
class AddWalletAddressToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :wallet_address, :string
  end
end
