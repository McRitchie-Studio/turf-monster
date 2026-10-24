# frozen_string_literal: true

require "openssl"
require "yaml"

module TurfMonster
  # Finds Solana secret keys written into text — the scanner behind
  # test/lib/committed_secret_key_guard_test.rb, which runs it over every file
  # git tracks. turf-monster is a PUBLIC repository: a key committed here is a
  # key published, and git history keeps it after the line is deleted. Mack's
  # devnet key (foUu…) sat in e2e/devnet-smoke.spec.js from 2026-04-12 until it
  # was retired on 2026-10-24 (task rotate-leaked-devnet-mack-key).
  #
  # WHAT COUNTS AS A SECRET KEY. A Solana keypair is 64 bytes: a 32-byte
  # Ed25519 seed followed by the 32-byte public key that seed derives. Two
  # spellings are caught:
  #
  #   * base58, 85-90 characters (87-88 in practice), decoding to 64 bytes;
  #   * a JSON-style array of 64 integers, each 0-255 (`solana-keygen`'s file).
  #
  # A candidate is a finding only when its second half IS the public key its
  # first half derives. That one check is what separates a secret key from a
  # transaction signature, which is also 64 bytes of base58 and fills this
  # repo's runbooks (measured 2026-10-24: 13 signatures, 0 keys, on the tree
  # after the fix). The check cannot miss a real keypair: every secret key
  # `solana-keygen`, web3.js or this app's Solana::Keypair writes satisfies it
  # by construction.
  #
  # NOT CAUGHT, stated so the guard is not over-read: a bare 32-byte seed, a key
  # in hex or split across string pieces, and anything in an untracked file.
  #
  # THE ALLOW-LIST (config/committed_secret_key_allowlist.yml) names a
  # throwaway fixture key by its PUBLIC key, never by the secret, with the
  # reason it is safe to publish. An entry the scan no longer finds is itself a
  # failure: an exemption must keep measuring the thing it exempts.
  module CommittedSecretScan
    BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    BASE58_RUN = /(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{85,90}(?![1-9A-HJ-NP-Za-km-z])/
    BYTE_ARRAY = /\[\s*(?:\d{1,3}\s*,\s*){63}\d{1,3}\s*,?\s*\]/m
    ED25519_PKCS8_PREFIX = ["302e020100300506032b657004220420"].pack("H*")
    ALLOWLIST_PATH = "config/committed_secret_key_allowlist.yml"

    # One secret key found in one file. `pubkey` is the PUBLIC half, which is
    # safe to print; the secret is never kept on the struct.
    Finding = Struct.new(:path, :line, :form, :pubkey, keyword_init: true) do
      def to_s
        "#{path}:#{line} holds a Solana secret key (#{form}) for public key #{pubkey}"
      end
    end

    module_function

    # @param path [String] for the report only
    # @param text [String]
    # @return [Array<Finding>]
    def scan_text(path, text)
      text = text.dup.force_encoding(Encoding::UTF_8).scrub
      findings = []

      text.to_enum(:scan, BASE58_RUN).each do
        match = Regexp.last_match
        bytes = decode_base58(match[0])
        pubkey = keypair_pubkey(bytes)
        next unless pubkey

        findings << Finding.new(path: path, line: line_of(match), form: "base58", pubkey: pubkey)
      end

      text.to_enum(:scan, BYTE_ARRAY).each do
        match = Regexp.last_match
        ints = match[0].scan(/\d+/).map(&:to_i)
        next unless ints.size == 64 && ints.all? { |i| i <= 255 }

        pubkey = keypair_pubkey(ints.pack("C*"))
        next unless pubkey

        findings << Finding.new(path: path, line: line_of(match), form: "byte array", pubkey: pubkey)
      end

      findings
    end

    # Every file git tracks under `root`, binary files skipped.
    # @return [Array<Finding>]
    def scan_tracked(root)
      tracked_paths(root).flat_map do |rel|
        full = File.join(root.to_s, rel)
        next [] unless File.file?(full)

        body = File.binread(full)
        next [] if body.include?("\0")

        scan_text(rel, body)
      end
    end

    # @return [Array<String>] repo-relative paths git tracks under `root`
    def tracked_paths(root)
      paths = IO.popen(["git", "-C", root.to_s, "ls-files", "-z"], &:read).split("\0")
      raise "git ls-files listed nothing under #{root}" if paths.empty?

      paths
    end

    # @return [Hash{String=>String}] public key => reason
    def allowlist(root)
      raw = YAML.safe_load_file(File.join(root.to_s, ALLOWLIST_PATH)) || {}
      entries = raw.fetch("allowed", nil) || []
      entries.to_h do |e|
        pubkey = e.fetch("pubkey").to_s
        reason = e.fetch("reason").to_s.strip
        raise "#{ALLOWLIST_PATH}: #{pubkey} has no reason" if reason.empty?

        [pubkey, reason]
      end
    end

    # The public key `bytes` carries in its second half, when `bytes` is a
    # well-formed 64-byte Ed25519 keypair; otherwise nil.
    def keypair_pubkey(bytes)
      return nil unless bytes&.bytesize == 64

      seed = bytes.byteslice(0, 32)
      claimed = bytes.byteslice(32, 32)
      derived = OpenSSL::PKey.read(ED25519_PKCS8_PREFIX + seed).public_to_der.byteslice(-32, 32)
      derived == claimed ? encode_base58(claimed) : nil
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    def decode_base58(str)
      int = 0
      str.each_char do |c|
        digit = BASE58_ALPHABET.index(c)
        return nil if digit.nil?

        int = int * 58 + digit
      end
      hex = int.zero? ? "" : int.to_s(16)
      hex = "0#{hex}" if hex.size.odd?
      ("\x00" * str[/\A1*/].size).b + [hex].pack("H*")
    end

    def encode_base58(bytes)
      int = bytes.unpack1("H*").to_i(16)
      out = +""
      while int.positive?
        int, rem = int.divmod(58)
        out.prepend(BASE58_ALPHABET[rem])
      end
      ("1" * bytes.bytes.take_while(&:zero?).size) + out
    end

    def line_of(match)
      match.pre_match.count("\n") + 1
    end
  end
end
