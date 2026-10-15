# Labels for the wallets a co-sign picker offers, read from the committed
# public roster (config/signer_roster.yml) so the operator can tell his own
# wallet from an agent key without matching base58 by eye.
module CosignWalletHelper
  # "3Qj4…ZboA · Alex, second wallet", or for a key he does not hold,
  # "3LTL…pJ9 · Governance key v2 (agent key, break-glass)". An address the
  # roster does not know says so rather than passing as anyone's.
  def cosign_wallet_option_label(address, roster: Solana::SignerRoster.default)
    address = address.to_s
    short = address.length > 12 ? "#{address[0, 4]}…#{address[-4, 4]}" : address
    entry = roster[address]

    who = if entry.nil?
      "Unknown key"
    elsif entry.alex?
      entry.name
    else
      "#{entry.name} (agent key, break-glass)"
    end

    "#{short} · #{who}"
  end
end
