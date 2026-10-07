# The columns an entry carries once it has been entered on chain from `wallet`:
# its slot and the ContestEntry PDA the program derived from
# [b"entry", sha256(contest slug), wallet, entry_num]. Saving them lets
# Entry#record_entering_wallet prove the entering wallet the way production
# does, so a settle test pays a wallet that really entered.
module EnteredOnchain
  module_function

  def attrs(contest, wallet, entry_number: 0)
    pda = Solana::Vault.new(client: nil).entry_pda(contest.slug, wallet, entry_number).first
    { entry_number: entry_number, onchain_entry_id: Solana::Keypair.encode_base58(pda) }
  end

  def random_wallet
    Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58
  end
end
