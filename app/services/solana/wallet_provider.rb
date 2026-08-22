# frozen_string_literal: true

# The canonical registry of self-custody Solana wallet brands.
#
# ONE list, so the three places that name a wallet cannot drift: the connect
# picker's install rows, the `web3_wallet_provider` column we stamp at signature
# time, and the step-up modal that leads with "Continue with Phantom". Before
# this, the brand names lived as a JS literal inside _wallet_connect.html.erb and
# nowhere else — fine while nothing PERSISTED them, wrong the moment a column
# does, because a typo'd brand would be stored and then never match again.
#
# WHY IT LIVES HERE (and not yet in the gem): solana-studio owns the web3
# primitives and already ships a Rails half (app/views/solana_studio/modals/
# _network_mismatch.html.erb), which is this registry's eventual home. Consuming
# it there needs a gem release, so it is authored in the `Solana::` namespace
# the gem owns — when solana-studio ships it, this file is DELETED and the
# constant resolves to the gem's with no callsite touched. That is the same
# build-in-app-then-lift path the modal registry and the adopt-engine-* tasks
# already walk.
#
# Normalisation is the whole point of the public API: `normalize` is the only
# way a client-supplied string becomes a stored value, and it returns nil for
# anything not on this list. An unknown wallet is not an error — it is a user on
# a brand we do not have artwork for, and the correct outcome is to remember
# nothing and show them the picker.
module Solana
  module WalletProvider
    # key   — the stored value + the engine sprite suffix (#se-wallet-<key>)
    # label — how the brand writes its own name, for UI
    # install_url — where a user without it goes
    REGISTRY = [
      { key: "phantom",  label: "Phantom",  install_url: "https://phantom.app/download" },
      { key: "solflare", label: "Solflare", install_url: "https://solflare.com/download" },
      { key: "backpack", label: "Backpack", install_url: "https://backpack.app/downloads" }
    ].freeze

    KEYS = REGISTRY.map { |w| w[:key] }.freeze

    module_function

    # The ONLY sanctioned string -> stored value conversion. Case-insensitive
    # and whitespace-tolerant because the value arrives from a browser that read
    # it off a Wallet Standard registration ("Phantom", "phantom", " Solflare ").
    # Returns nil for anything unknown, which every caller treats as "no
    # remembered wallet" rather than as a failure.
    def normalize(name)
      key = name.to_s.strip.downcase
      key if KEYS.include?(key)
    end

    def known?(name)
      normalize(name).present?
    end

    # The registry row for a brand, or nil. Callers use it for the label and the
    # install URL; the sprite id is just "se-wallet-#{key}".
    def find(name)
      key = normalize(name)
      REGISTRY.find { |w| w[:key] == key } if key
    end

    # How the brand writes its own name ("Phantom"), or nil when unknown — the
    # step-up modal's headline CTA reads this, and a nil sends it to the picker.
    def label(name)
      find(name)&.fetch(:label)
    end

    def install_url(name)
      find(name)&.fetch(:install_url)
    end
  end
end
