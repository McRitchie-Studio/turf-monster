# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# See ActiveSupport::ParameterFilter for supported notations and behaviors.
#
# OPSEC-038: expanded for Solana/web3 + payment-flow specifics. The general
# patterns (`_key`, `crypt`, `secret`, `token`) cover most secrets but miss
# Solana-specific fields and the signed-tx blob that admin endpoints handle.
Rails.application.config.filter_parameters += [
  # General secret matchers (substring containment)
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,

  # Web3 / Solana
  :signature,       # also catches tx_signature, webhook_signature, signatures
  :serialized_tx,   # base64-encoded signed transactions on admin endpoints
  :signed_tx,       # the fully-signed wire every cosign broadcast posts; a nonce-anchored one stays landable
  :tx_signature,
  :pubkey,          # not strictly secret but enables user correlation in logs
  :signers,         # admin/authorities#arm: public keys, but a pasted secret would land here too
  :authorizers,     # admin/authorities#arm: the same, for the wallets that authorize the rotation
  :nonce,           # solana_sessions nonces — limited TTL, but no need to log
  :recovery_phrase,
  :mnemonic,
  :private_key,
]
