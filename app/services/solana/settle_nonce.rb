module Solana
  # Which settle path this cluster takes, read from config/settle_nonce.yml.
  #
  # `.current` is nil when the cluster's entry is off: settle then builds on a
  # recent blockhash for the Phantom cosign, unchanged. When on, it returns the
  # nonce account and the CLI cosigner, which is also the nonce authority.
  # An enabled entry with a blank or malformed key raises ConfigError.
  class SettleNonce
    CONFIG_PATH = Rails.root.join("config/settle_nonce.yml")
    ENV_SWITCH = "SETTLE_DURABLE_NONCE".freeze
    ON = %w[1 true on yes].freeze
    OFF = %w[0 false off no].freeze

    class ConfigError < StandardError; end

    Settings = Data.define(:network, :nonce_account, :cosigner) do
      # The `durable_nonce:` argument Solana::Vault#build_settle_contest takes.
      def durable_nonce
        { pubkey: nonce_account, authority: cosigner }
      end
    end

    def self.current(network: Config::NETWORK, env: ENV, path: CONFIG_PATH)
      new(network: network, env: env, path: path).current
    end

    # The settle build for this cluster. Off: the blockhash build with the
    # default cosigner, byte for byte what it was. On: the nonce-anchored build
    # with the CLI cosigner, plus the metadata a queued row carries.
    def self.build_settle(vault:, slug:, settlements:, default_cosigner:, extra_cosigners: [], settings: current)
      unless settings
        result = vault.build_settle_contest(slug, settlements, cosigner_pubkey: default_cosigner,
                                                               extra_cosigners: extra_cosigners)
        return result.merge(cosigner: default_cosigner)
      end

      result = vault.build_settle_contest(slug, settlements, cosigner_pubkey: settings.cosigner,
                                                             extra_cosigners: extra_cosigners,
                                                             durable_nonce: settings.durable_nonce)
      result.merge(cosigner: settings.cosigner,
                   durable_nonce: { "account" => settings.nonce_account,
                                    "authority" => settings.cosigner,
                                    "value" => result.fetch(:nonce_value) })
    end

    def initialize(network:, env:, path:)
      @network = network.to_s
      @env = env
      @path = path
    end

    def current
      entry = entries[@network]
      return nil unless enabled?(entry)
      raise ConfigError, "#{ENV_SWITCH} is on but config/settle_nonce.yml has no #{@network} entry" unless entry

      Settings.new(network: @network,
                   nonce_account: pubkey!(entry, "nonce_account"),
                   cosigner: pubkey!(entry, "cosigner"))
    end

    private

    def entries
      @entries ||= begin
        data = YAML.safe_load_file(@path)
        raise ConfigError, "config/settle_nonce.yml is not a mapping" unless data.is_a?(Hash)

        data
      end
    end

    def enabled?(entry)
      switch = @env[ENV_SWITCH].to_s.strip.downcase
      return true if ON.include?(switch)
      return false if OFF.include?(switch)
      raise ConfigError, "#{ENV_SWITCH}=#{@env[ENV_SWITCH].inspect} is not on or off" unless switch.empty?

      entry.is_a?(Hash) && entry["enabled"] == true
    end

    def pubkey!(entry, key)
      value = entry[key].to_s.strip
      raise ConfigError, "settle nonce is on for #{@network} but #{key} is blank" if value.empty?

      bytes = Keypair.decode_base58(value)
      raise ConfigError, "#{@network} #{key} #{value} is not a 32-byte public key" unless bytes.bytesize == 32

      value
    rescue ArgumentError => e
      raise ConfigError, "#{@network} #{key} #{value} is not base58: #{e.message}"
    end
  end
end
