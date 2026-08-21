module Cdp
  # Resolves the §10 / open-question-3 `to_address` ambiguity ON-CHAIN before
  # any offramp USDC send (docs/CDP_RAMP_INTEGRATION.md): the Offramp
  # Transaction Status API hands us "a Coinbase managed onchain address" but
  # no doc says whether that is an OWNER (wallet) address or an SPL TOKEN
  # ACCOUNT. Sending USDC to the wrong shape strands real funds, so this
  # resolver gates EVERY send (managed server-sign AND Phantom prepare):
  #
  #   1. Fetch the account. Owned by the SPL Token program → it IS a token
  #      account; verify its mint is USDC and use it directly.
  #   2. Anything else (system-owned wallet, or not yet on-chain) → treat it
  #      as an owner address and derive its USDC ATA — which must itself
  #      exist as a token account (we never pay rent to create a
  #      Coinbase-side ATA on a guess).
  #   3. Neither resolves → raise the typed ResolutionError (fail CLOSED; the
  #      first mainnet sell settles the semantics for good).
  #
  # Transient RPC faults propagate as Solana::Client::RpcError so callers can
  # retry; ResolutionError is SEMANTIC (retrying won't help).
  class OfframpDestination
    class ResolutionError < StandardError; end

    TOKEN_PROGRAM_ID_B58 = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".freeze

    # token_account — base58 address the SPL transfer must target
    # kind          — :token_account (to_address used directly) | :owner_ata
    Result = Struct.new(:token_account, :kind, keyword_init: true)

    def self.resolve(to_address, client: nil)
      new(client: client || Solana::Config.client).resolve(to_address)
    end

    def initialize(client: Solana::Config.client)
      @client = client
    end

    def resolve(to_address)
      raise ResolutionError, "to_address is blank" if to_address.blank?
      validate_pubkey!(to_address)

      info = account_value(to_address)
      if token_account?(info)
        verify_usdc_mint!(to_address, info)
        return Result.new(token_account: to_address, kind: :token_account)
      end

      ata = derive_usdc_ata(to_address)
      ata_info = account_value(ata)
      unless token_account?(ata_info)
        raise ResolutionError,
              "to_address #{to_address} is not an SPL token account and its derived " \
              "USDC ATA #{ata} does not exist on-chain — refusing to send " \
              "(open question 3: confirm to_address semantics on the first mainnet sell)"
      end
      Result.new(token_account: ata, kind: :owner_ata)
    end

    private

    def account_value(address)
      @client.get_account_info(address)&.dig("value")
    end

    def token_account?(info)
      info.is_a?(Hash) && info["owner"] == TOKEN_PROGRAM_ID_B58
    end

    # SPL token-account layout: bytes 0..31 = mint. A token account for the
    # wrong mint would make the transfer fail on-chain anyway — fail closed
    # here with a diagnosable error instead.
    def verify_usdc_mint!(address, info)
      data_b64 = info.dig("data", 0)
      raise ResolutionError, "token account #{address} returned no data" if data_b64.blank?

      data = Base64.decode64(data_b64)
      raise ResolutionError, "token account #{address} data too short" if data.bytesize < 32

      mint = Solana::Keypair.encode_base58(data.byteslice(0, 32))
      return if mint == Solana::Config::USDC_MINT

      raise ResolutionError,
            "to_address #{address} is a token account for mint #{mint}, not USDC " \
            "(#{Solana::Config::USDC_MINT})"
    end

    def derive_usdc_ata(owner_address)
      ata_bytes, _ = Solana::SplToken.find_associated_token_address(
        owner_address, Solana::Config::USDC_MINT
      )
      Solana::Keypair.encode_base58(ata_bytes)
    end

    def validate_pubkey!(address)
      bytes = Solana::Keypair.decode_base58(address)
      raise ResolutionError, "to_address #{address} is not a 32-byte pubkey" unless bytes&.bytesize == 32
    rescue ResolutionError
      raise
    rescue StandardError
      raise ResolutionError, "to_address #{address} is not valid base58"
    end
  end
end
