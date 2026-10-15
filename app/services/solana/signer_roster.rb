module Solana
  # The committed public signer roster, config/signer_roster.yml: who each named
  # key belongs to and how it signs. The console reads it to label seated keys,
  # to offer keys to add, and to decide which seated keys may be asked for in
  # Phantom (only `holder: alex`), and in WHAT ORDER (`priority`).
  #
  # PUBLIC HALVES ONLY, AND THE LOADER ENFORCES IT. The roster ships to every
  # browser that opens /admin/authorities, so a secret pasted into it would be
  # published. Every address must decode to exactly 32 bytes; a 64-byte decode
  # is a secret key and the whole file is refused, naming the entry's NAME and
  # never the value.
  class SignerRoster
    PATH = Rails.root.join("config/signer_roster.yml").freeze

    HOLDERS = %w[alex agent].freeze
    SIGNS_IN = %w[phantom server script].freeze
    CLUSTERS = %w[mainnet-beta devnet].freeze

    class InvalidRoster < StandardError; end

    Entry = Struct.new(:address, :name, :holder, :signs_in, :clusters, :op_item, :role, :priority,
                       keyword_init: true) do
      def alex? = holder == "alex"
      def phantom? = signs_in == "phantom"

      def to_h_public
        { address: address, name: name, holder: holder, signs_in: signs_in,
          clusters: clusters, op_item: op_item, role: role, priority: priority }
      end
    end

    def self.load(path = PATH)
      new(YAML.safe_load_file(path))
    end

    # Memoized per process; the file is committed and cannot change under a
    # running app.
    def self.default
      @default ||= load
    end

    def self.reset!
      @default = nil
    end

    attr_reader :entries

    def initialize(document)
      rows = document.is_a?(Hash) ? document["keys"] : nil
      raise InvalidRoster, "signer roster has no `keys:` list" unless rows.is_a?(Array)

      @entries = rows.each_with_index.map { |row, i| entry_from(row, i) }
      dupes = @entries.map(&:address).tally.select { |_, n| n > 1 }.keys
      raise InvalidRoster, "signer roster lists #{dupes.join(', ')} more than once" if dupes.any?

      ranks = @entries.filter_map(&:priority)
      clash = ranks.tally.select { |_, n| n > 1 }.keys
      raise InvalidRoster, "signer roster gives priority #{clash.join(', ')} to more than one key" if clash.any?

      @by_address = @entries.index_by(&:address)
    end

    def [](address) = @by_address[address.to_s.strip]

    def include?(address) = @by_address.key?(address.to_s.strip)

    # Keys that may be a VaultState signer on `network`.
    def for_cluster(network)
      entries.select { |entry| entry.clusters.include?(network.to_s) }
    end

    # Mr. McRitchie's keys: the only ones the console ever asks Phantom for.
    def alex_addresses = entries.select(&:alex?).map(&:address)

    # Mr. McRitchie's keys IN THE ORDER HE WANTS THEM ASKED FOR: by `priority`,
    # then (for an unranked alex key) file order. The one source of truth for
    # which of his wallets fills a Phantom slot first, read by the co-sign
    # card (Solana::CosignPlan) and the signer console (Solana::SignerPlan).
    #
    # It exists because both surfaces used to inherit VaultState SLOT order,
    # and slot 0 on mainnet is 3LTL, an agent key: on 2026-10-14 the co-sign
    # card for ptx-437 defaulted its second wallet to it.
    def operator_priority
      entries.each_with_index
             .select { |entry, _| entry.alex? }
             .sort_by { |entry, i| [entry.priority || Float::INFINITY, i] }
             .map { |entry, _| entry.address }
    end

    # Is `address` one of Mr. McRitchie's own keys? Unknown keys are not.
    def operator?(address) = self[address]&.alex? || false

    # `addresses` reordered for a picker: his seated keys first, in priority
    # order, then every other key (agent-held or unknown) in the order given.
    # Nothing is dropped; only the operator's keys may lead.
    def by_operator_priority(addresses)
      addresses = Array(addresses).map(&:to_s)
      ranked = operator_priority & addresses
      ranked + (addresses - ranked)
    end

    private

    def entry_from(row, index)
      raise InvalidRoster, "signer roster entry #{index + 1} is not a mapping" unless row.is_a?(Hash)

      label = row["name"].presence || "entry #{index + 1}"
      address = row["address"].to_s.strip
      check_public_key!(address, label)

      holder = row["holder"].to_s
      raise InvalidRoster, "#{label}: holder must be one of #{HOLDERS.join(', ')}" unless HOLDERS.include?(holder)

      signs_in = row["signs_in"].to_s
      raise InvalidRoster, "#{label}: signs_in must be one of #{SIGNS_IN.join(', ')}" unless SIGNS_IN.include?(signs_in)

      clusters = Array(row["clusters"]).map(&:to_s)
      unknown = clusters - CLUSTERS
      raise InvalidRoster, "#{label}: unknown cluster #{unknown.join(', ')}" if unknown.any?

      Entry.new(address: address, name: label, holder: holder, signs_in: signs_in,
                clusters: clusters, op_item: row["op_item"].presence, role: row["role"].to_s,
                priority: priority_from(row, holder, label))
    end

    # A priority is a positive integer, and ONLY on an `alex` key: a ranked
    # agent key would be a default the operator never chose.
    def priority_from(row, holder, label)
      return nil if row["priority"].nil?

      raise InvalidRoster, "#{label}: only an `alex` key takes a priority" unless holder == "alex"

      value = row["priority"]
      raise InvalidRoster, "#{label}: priority must be a positive integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    # Never echoes the value: a value that fails here may be a secret.
    def check_public_key!(address, label)
      bytes = begin
        SignerIsolation.decode_base58(address)
      rescue ArgumentError
        raise InvalidRoster, "#{label}: address is not base58"
      end

      if bytes.bytesize == 64 || address.length > 44
        raise InvalidRoster, "#{label}: the value is shaped like a SECRET key, not an address. " \
                             "Remove it from config/signer_roster.yml and rotate that key."
      end
      raise InvalidRoster, "#{label}: address is not 32 bytes" unless bytes.bytesize == 32
      raise InvalidRoster, "#{label}: the zero key is not a signer" if bytes == ("\x00" * 32).b
    end
  end
end
