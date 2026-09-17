# Wallet self-custody export (task #11).
#
# Stage 1 (live, AccountsController#initiate_wallet_export):
#   - eligibility check + recent-password reauth
#   - stamps export_initiated_at, mints a 30-min signed token
#   - emails the user a magic link → #show below
#
# Stage 2 (this controller):
#   show     — verify the URL token, decrypt the user's keypair, render the
#              reveal page with the secret key as both Solana CLI JSON array
#              and base58 alongside a Phantom-sign challenge.
#   complete — verify a Phantom signature over the challenge message, set
#              users.self_custodied_at so downstream call sites stop
#              server-signing on this user's behalf (Stage 3 — separate PR).
#
# Auth model:
#   - The URL token (`:token`) is the auth boundary. It binds (user_id, email,
#     export_initiated_at) and is signed by Rails.application.message_verifier.
#     A user opening the email on a different device than the one they're
#     logged in on must still reach the reveal page, so we skip
#     require_authentication.
#   - The Phantom signature for #complete is verified server-side via
#     ed25519. The signed-message format is fixed and includes the URL token
#     (so a signature captured for a different export can't be replayed).
class WalletExportsController < ApplicationController
  WALLET_EXPORT_TOKEN_KEY = AccountsController::WALLET_EXPORT_TOKEN_KEY

  skip_before_action :require_authentication, only: [:show, :complete]
  # Magic-link visitors don't have a CSRF token. The token + ed25519 signature
  # together are the auth surface for #complete; CSRF would just block legit
  # users who clicked the email link on a different device.
  skip_before_action :verify_authenticity_token, only: [:complete]

  before_action :verify_export_token, only: [:show, :complete]
  before_action :harden_secret_response, only: [:show]

  def show
    keypair = @export_user.solana_keypair
    raise "No managed keypair on file — this account may already be self-custodied" if keypair.nil?

    @address = @export_user.solana_address

    # 64-byte secret = signing_key (32) + public_key (32). This is exactly
    # what the Solana CLI writes to disk as a JSON array and what Phantom
    # accepts as a base58 "private key" paste.
    secret_bytes = keypair.to_bytes
    @secret_json_array = "[" + secret_bytes.bytes.join(",") + "]"
    @secret_base58     = Solana::Keypair.encode_base58(secret_bytes)

    @sign_message = self.class.prove_message(token: params[:token], address: @address)

    render :show
  rescue StandardError => e
    Rails.logger.error "[wallet-export] show failed user=#{@export_user&.id}: #{e.class}: #{e.message}"
    render plain: "Could not show your wallet: #{e.message}", status: :unprocessable_entity
  end

  def complete
    signature_b58 = params.require(:signature)
    submitted_msg = params.require(:message).to_s

    # Defensive: refuse to verify a signature over anything but the exact
    # message we issued. Without this, an attacker who tricks the user into
    # signing some other arbitrary thing could replay that signature here.
    expected_msg = self.class.prove_message(token: params[:token], address: @export_user.solana_address)
    raise "Unexpected message format" unless ActiveSupport::SecurityUtils.secure_compare(submitted_msg, expected_msg)

    pubkey_bytes = Solana::Keypair.decode_base58(@export_user.solana_address)
    sig_bytes    = Solana::Keypair.decode_base58(signature_b58)
    Ed25519::VerifyKey.new(pubkey_bytes).verify(sig_bytes, expected_msg)
    # A small-order address is refused like a signature that did not verify.
    # Stopgap until solana-studio ships Ed25519Strict — see Solana::ForgeableSigninKeys.
    Solana::ForgeableSigninKeys.refuse!(@export_user.solana_address, context: "wallet_exports#complete")

    @export_user.update!(self_custodied_at: Time.current)
    Rails.logger.info "[wallet-export] self_custodied user=#{@export_user.id} address=#{@export_user.solana_address}"
    render json: { success: true, redirect: account_path }
  rescue Ed25519::VerifyError, Solana::AuthVerifier::VerificationError
    render json: { success: false, error: "Signature didn't verify against your wallet — make sure you signed with the imported wallet." }, status: :unprocessable_entity
  rescue ActionController::ParameterMissing => e
    render json: { success: false, error: "Missing #{e.param}" }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[wallet-export] complete failed user=#{@export_user&.id}: #{e.class}: #{e.message}"
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Canonical prove-custody message. Public + class-level so #show, #complete,
  # and tests construct the same string.
  def self.prove_message(token:, address:)
    "Turf Monster: I confirm self-custody of my wallet #{address}.\n" \
    "Token: #{token}\n" \
    "Signing this message proves I control this wallet's private key. " \
    "After signing, Turf Monster will stop auto-signing on my behalf."
  end

  private

  # Lazarus audit #2 (2026-05-31): #show renders the decrypted private key into
  # the DOM. Suppress third-party session replay (LogRocket — see
  # ApplicationHelper#session_replay_active?) so the key + the owner's identity
  # are never streamed off-box, and forbid caching / referrer leakage of the
  # reveal page.
  def harden_secret_response
    @suppress_session_replay = true
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

  def verify_export_token
    payload = Rails.application.message_verifier(WALLET_EXPORT_TOKEN_KEY).verify(params[:token]).with_indifferent_access
    @export_user = User.find_by(id: payload[:user_id])

    raise "Unknown account" unless @export_user
    raise "Token issued for a different email" unless @export_user.email.to_s.downcase == payload[:email].to_s.downcase
    raise "A newer export link was issued — use the most recent one" unless @export_user.export_initiated_at.to_i == payload[:initiated_at].to_i
    raise "Wallet is already self-custodied"                          if @export_user.self_custodied?
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render plain: "This export link is invalid or expired. Request a fresh one from your account page.", status: 410
  rescue StandardError => e
    Rails.logger.warn "[wallet-export] token verify failed: #{e.class}: #{e.message}"
    render plain: e.message, status: 410
  end
end
