# frozen_string_literal: true

module Solana
  # THE WALLET THIS SESSION IS SIGNED IN WITH, and what to paint for it.
  #
  # A value object over one session key, so every surface that shows the current
  # wallet — avatar, colour, name — reads the same answer from the same place
  # instead of each re-deriving it from the user row.
  #
  # WHY SESSION AND NOT THE USER COLUMN, which is the distinction that decides
  # this whole class. `User#web3_wallet_provider` is a DURABLE record of which
  # brand an account last authenticated with; it survives logout on purpose,
  # because it is how the app knows which wallet to offer a returning user. This
  # is the narrower, per-session fact: which wallet is signed in RIGHT NOW. They
  # answer different questions, and conflating them would mean either a logged-out
  # browser still claiming a current wallet, or the account forgetting its brand
  # every time someone signs out.
  #
  # THE BOOKENDS, and why they sit exactly where they do. The session key is
  # written and cleared alongside `:onchain`, which is the same shape of fact (a
  # privilege granted by a live wallet signature) and therefore already has the
  # three seams right:
  #
  #   ApplicationController#set_app_session   -> CLEARED. Every login starts with
  #     no current wallet, so a Phantom session cannot leak its brand into a later
  #     email or Google login on the same browser.
  #   SolanaSessionsController#verify         -> SET. This is the only path that
  #     proves a wallet by signature, and it covers BOTH first auth and a wallet
  #     SWITCH, because a switch re-auths through the same endpoint.
  #   ApplicationController#clear_app_session -> CLEARED, on logout.
  #
  # An unknown or absent brand is not an error. It resolves to WalletProvider's
  # DEFAULT row, so callers always get an avatar and a colour and never have to
  # branch on nil.
  class CurrentWallet
    SESSION_KEY = :wallet_brand

    # Read the current wallet out of a session. `session` is anything that
    # responds to [] — a real session, or a plain hash in a test.
    def self.from_session(session)
      new(session && session[SESSION_KEY])
    end

    # Remember the brand a signature just proved. Stores the NORMALISED key, so
    # whatever spelling the browser read off a Wallet Standard registration
    # ("Phantom", "phantom", " Solflare ") lands as one canonical value — and an
    # unrecognised brand stores nothing rather than a value that can never match.
    def self.remember(session, provider)
      key = WalletProvider.normalize(provider)
      key ? session[SESSION_KEY] = key : session.delete(SESSION_KEY)
      key
    end

    def self.forget(session)
      session.delete(SESSION_KEY)
    end

    def initialize(key = nil)
      @key = WalletProvider.normalize(key)
    end

    attr_reader :key

    # True only for a brand the registry knows. Callers use it to decide whether
    # to NAME the wallet ("Continue with Phantom") — never to decide whether to
    # render an avatar, which is always safe.
    def known? = @key.present?

    def label = brand.fetch(:label)

    # The engine sprite id to <use>: "se-wallet-phantom", or the neutral mark.
    def avatar = WalletProvider.avatar(@key)

    # The brand's primary colour, or the neutral slate. Always a CSS hex.
    def colour = brand.fetch(:colour)

    def to_h = { key: @key, label: label, avatar: avatar, colour: colour, known: known? }

    private

    def brand = WalletProvider.brand(@key)
  end
end
