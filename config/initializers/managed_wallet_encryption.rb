# OPSEC-015: managed-wallet private keys (users.encrypted_web2_solana_private_key)
# are encrypted with a 256-bit key derived from MANAGED_WALLET_ENCRYPTION_KEY
# (see Solana::Keypair). In production the env var is mandatory — fail fast at
# boot rather than at the first wallet operation.
#
# Dev / test / CI fall back to secret_key_base run through the same KDF — a
# proper 256-bit key, just not rotation-isolated. Production must use a
# dedicated key so secret_key_base can be rotated independently.
#
# Rotating THIS key needs MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS (decrypt-only)
# for the length of the migration — see docs/SOLANA.md "Rotating the
# managed-wallet key". Deliberately NOT validated here: a boot guard that
# judged the previous key's format would take production down over a value that
# only has to open old rows, and the rotation task already proves that it does.
if Rails.env.production? && ENV["MANAGED_WALLET_ENCRYPTION_KEY"].blank?
  raise <<~MSG
    MANAGED_WALLET_ENCRYPTION_KEY required in production (OPSEC-015).

    Generate:  ruby -e 'require "securerandom"; puts SecureRandom.hex(32)'
    Set:       heroku config:set MANAGED_WALLET_ENCRYPTION_KEY=<value> --app turf-monster-mainnet
    Migrate:   heroku run bin/rails solana:reencrypt_managed_wallets --app turf-monster-mainnet

    Until reencrypt_managed_wallets runs, legacy-encrypted rows still decrypt
    (Solana::Keypair handles both schemes) — but new wallets use v2 from the
    moment this key is set.
  MSG
end
