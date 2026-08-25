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
    # colour — the brand's PRIMARY, SAMPLED FROM ITS OWN ARTWORK rather than
    #   transcribed from a brand page. studio-engine already embeds each wallet's
    #   official logo in app/views/studio/modals/blocks/_wallet_brand_sprite.html.erb
    #   as a base64 PNG, so the authoritative colour is sitting in this repo's
    #   dependency: decode the PNG, drop pixels under 250 alpha, take the most
    #   common remaining RGB. That is the tile each mark is drawn on. The method
    #   validates itself — Phantom resolves to AB9FF2, which is the brand purple
    #   Phantom publishes. Re-derive the same way if a mark is ever replaced;
    #   do not hand-edit these toward something that looks nicer, because the
    #   point of the value is that it MATCHES the avatar sitting next to it.
    REGISTRY = [
      { key: "phantom",  label: "Phantom",  colour: "#AB9FF2",
        install_url: "https://phantom.app/download" },
      { key: "solflare", label: "Solflare", colour: "#FFEE00",
        install_url: "https://solflare.com/download" },
      { key: "backpack", label: "Backpack", colour: "#E33E3F",
        install_url: "https://backpack.app/downloads" }
    ].freeze

    # The base case: a wallet whose brand we do not recognise, or no wallet at
    # all. It is a REAL ROW, not a nil — every surface that shows a wallet gets
    # an avatar and a colour, so it keeps ONE shape whether the brand is known or
    # not. A surface that hid the avatar instead would have two layouts and the
    # rarer one would rot unseen.
    #
    # The colour is deliberately a neutral slate rather than a fourth brand hue:
    # it must not read as "some wallet you have heard of". The engine's
    # se-wallet-default mark paints in currentColor, so it takes this.
    DEFAULT = { key: nil, label: "Wallet", colour: "#7C7A85",
                install_url: nil }.freeze

    KEYS = REGISTRY.map { |w| w[:key] }.freeze

    # The engine sprite ids. Kept as a prefix plus the key rather than stored per
    # row, because that IS the engine's convention and duplicating it here would
    # let the two drift silently.
    SPRITE_PREFIX = "se-wallet-"
    DEFAULT_SPRITE = "#{SPRITE_PREFIX}default"

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

    # --- always-resolving accessors -----------------------------------------
    #
    # `find` and friends above return NIL for an unknown brand ON PURPOSE, and
    # that stays: their callers use the nil to decide whether to remember a
    # wallet at all, or to fall back to the picker. Do not "fix" them.
    #
    # These are the other question — "what do I PAINT for this wallet?" — and it
    # always has an answer. A caller rendering an avatar has no useful branch to
    # take on nil; it would only reintroduce the missing-artwork hole the
    # DEFAULT row exists to close.

    # The registry row for a brand, ALWAYS — the default row when unknown.
    def brand(name)
      find(name) || DEFAULT
    end

    # The engine sprite id to <use>, e.g. "se-wallet-phantom".
    def avatar(name)
      key = normalize(name)
      key ? "#{SPRITE_PREFIX}#{key}" : DEFAULT_SPRITE
    end

    # The brand's primary colour as a CSS hex, for tinting the avatar and any
    # surface that is standing in for the wallet.
    def colour(name)
      brand(name).fetch(:colour)
    end
  end
end
