require "base64"
require "digest"
require "json"
require "solana_studio"

module Solana
  # Offline cosign of a nonce-anchored settle wire. Pure Ruby: no Rails, no
  # database, no RPC, so it runs on a machine that is never online.
  #
  # Every entry point first checks the wire is nonce-anchored (instruction 0 is
  # advanceNonceAccount), so a blockhash settle is never signed here.
  module SettleNonceSigner
    class Refused < StandardError; end

    ADVANCE_NONCE_DATA = [4].pack("V").freeze
    LEDGER_SCHEME = "usb://".freeze

    module_function

    # Fill `keypair`'s slot. Returns the patched wire, base64.
    def sign(wire_base64, keypair)
      assert_nonce_anchored!(wire_base64)
      bytes = Transaction.cosign_wire(Base64.decode64(wire_base64), signer: keypair, require_complete: false)
      Base64.strict_encode64(bytes)
    end

    # Write a detached signature (from a Ledger or any external signer) into
    # `pubkey`'s slot, after proving it signs these exact message bytes.
    def attach(wire_base64, pubkey:, signature_base58:)
      assert_nonce_anchored!(wire_base64)
      wire = WireMessage.parse_base64(wire_base64)
      key = Keypair.decode_base58(pubkey)
      index = wire.signer_keys.index(key)
      raise Refused, "#{pubkey} holds no signer slot in this transaction" unless index
      raise Refused, "slot #{index} (#{pubkey}) already holds a signature" unless wire.signature_slot_empty?(index)

      signature = Keypair.decode_base58(signature_base58)
      raise Refused, "a signature is 64 bytes; got #{signature.bytesize}" unless signature.bytesize == 64
      unless Ed25519Strict.verify(key, signature, wire.message_bytes)
        raise Refused, "that signature is not #{pubkey}'s over this message"
      end

      bytes = wire.to_bytes
      _count, offset = Transaction.read_compact_u16(bytes, 0)
      bytes[offset + (index * 64), 64] = signature
      Base64.strict_encode64(bytes)
    end

    # What the operator is about to sign, and which slots are filled.
    def describe(wire_base64)
      wire = WireMessage.parse_base64(wire_base64)
      advance = wire.instructions.first
      {
        nonce_anchored: nonce_anchored?(wire),
        nonce_account: advance && Keypair.encode_base58(advance[:accounts][0].to_s),
        nonce_value: wire.recent_blockhash_base58,
        message_sha256: Digest::SHA256.hexdigest(wire.message_bytes),
        signers: wire.signer_keys.each_with_index.map do |key, i|
          { pubkey: Keypair.encode_base58(key), signed: !wire.signature_slot_empty?(i), valid: wire.signature_valid?(i) }
        end
      }
    end

    # A Solana CLI keypair file. A `usb://` path names a hardware wallet,
    # which this signer cannot drive; attach its detached signature instead.
    def load_keypair(path)
      if path.to_s.start_with?(LEDGER_SCHEME)
        raise Refused, "#{path} is a hardware wallet. The Solana CLI has no command that signs an " \
                       "arbitrary transaction message, so produce the Ledger's signature over " \
                       "`bin/settle-nonce message` with a Ledger signer and add it with " \
                       "`bin/settle-nonce attach` (docs/SOLANA.md, Durable-nonce settlement)"
      end

      bytes = JSON.parse(File.read(File.expand_path(path)))
      raise Refused, "#{path} is not a Solana CLI keypair file (64-byte JSON array)" unless bytes.is_a?(Array) && bytes.size == 64

      keypair = Keypair.from_bytes(bytes)
      unless keypair.public_key_bytes == bytes.last(32).pack("C*")
        raise Refused, "#{path}: its public half does not match its secret half"
      end

      keypair
    end

    def assert_nonce_anchored!(wire_base64)
      return if nonce_anchored?(WireMessage.parse_base64(wire_base64))

      raise Refused, "instruction 0 is not advanceNonceAccount: this is not a nonce-anchored settle"
    end

    def nonce_anchored?(wire)
      first = wire.instructions.first
      !first.nil? && first[:program_id] == Transaction::SYSTEM_PROGRAM_ID && first[:data] == ADVANCE_NONCE_DATA
    end
  end
end
