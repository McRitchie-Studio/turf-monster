require "test_helper"

# Solana::Vault#fetch_wallet_balances must NORMALIZE connection-level transport
# failures to Solana::Client::RpcError.
#
# A Helius connection failure surfaces from the gem client as a RAW
# Errno::ECONNREFUSED (connection refused) / SocketError (DNS failure) — NOT an
# RpcError. solana-studio's Solana::Client#call wraps ONLY
# Net::OpenTimeout/Net::ReadTimeout/Errno::ECONNRESET into RpcError
# (lib/solana/client.rb#call); it never wraps ECONNREFUSED or SocketError. Left
# raw, that error escapes fetch_wallet_balances (get_balance used to sit OUTSIDE
# any rescue) and walks straight past the funding-decision callers'
# `rescue Solana::Client::RpcError` (Entries::ManagedEntry#fund!
# / #entry_funding_status) → a 500 / false-block on the entry path while the
# documented fail-open never fires.
#
# The fix lives at the vault boundary (not the controller), so these tests inject
# the failure BELOW fetch_wallet_balances — at the gem client (get_balance raises
# a raw connection error) — and exercise the REAL rescue. Deliberately NOT a
# generic RuntimeError: only transport-level failures are normalized; a genuine
# bug must still surface (see the controller's fail-CLOSED contract).
class Solana::VaultFetchWalletBalancesTransportTest < ActiveSupport::TestCase
  # Minimal Solana::Client stand-in whose reads raise the injected connection
  # error, mirroring what Net::HTTP raises when Helius is unreachable.
  class RaisingClient
    def initialize(error)
      @error = error
    end

    def get_balance(_addr)
      raise @error
    end

    def get_token_accounts_by_owner(_addr)
      raise @error
    end
  end

  CONNECTION_ERRORS = [
    Errno::ECONNREFUSED.new("Connection refused - connect(2) for Helius"),
    SocketError.new("getaddrinfo: nodename nor servname provided, or not known")
  ].freeze

  CONNECTION_ERRORS.each do |error|
    test "re-raises #{error.class} from get_balance as Solana::Client::RpcError under raise_on_read_error" do
      vault = Solana::Vault.new(client: RaisingClient.new(error))

      # RED against current code: get_balance sits outside any rescue, so the raw
      # #{error.class} escapes unwrapped (assert_raises would see the raw error,
      # not RpcError). GREEN after the fix: normalized to RpcError so the
      # funding-decision caller's `rescue Solana::Client::RpcError` fail-open fires.
      assert_raises(Solana::Client::RpcError) do
        vault.fetch_wallet_balances("Wa11etAddr1111111111111111111111111111111", raise_on_read_error: true)
      end
    end

    test "swallows #{error.class} to a zero/stale balance on the default navbar path" do
      vault = Solana::Vault.new(client: RaisingClient.new(error))

      # The documented default (raise_on_read_error: false) renders a stale/zero
      # pill, never an error — get_balance failing must not escape here either.
      result = vault.fetch_wallet_balances("Wa11etAddr1111111111111111111111111111111")

      assert_equal 0.0, result[:sol]
      assert_equal({}, result[:tokens])
    end
  end

  test "does NOT normalize a generic StandardError — a real bug must still surface" do
    # A decode error / NoMethodError is NOT a transport failure; the funding paths
    # deliberately fail CLOSED on it, so fetch_wallet_balances must let it escape
    # as-is (never disguise a bug as an RpcError fail-open).
    boom = Class.new do
      def get_balance(_addr)
        raise ArgumentError, "not a transport failure"
      end

      def get_token_accounts_by_owner(_addr)
        {}
      end
    end.new

    vault = Solana::Vault.new(client: boom)
    assert_raises(ArgumentError) do
      vault.fetch_wallet_balances("Wa11etAddr1111111111111111111111111111111", raise_on_read_error: true)
    end
  end
end
