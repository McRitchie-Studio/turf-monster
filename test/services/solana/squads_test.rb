require "test_helper"

# The Squads V4 multisig decoder.
#
# ── THE FIXTURE IS A REAL ACCOUNT, AND THAT IS THE POINT ─────────────────────
#
# `test/fixtures/files/squads_multisig_devnet.b64` is the live bytes of devnet
# multisig `7nRuVw3V…`, captured 2026-09-15. A synthetic fixture built by an
# encoder in this repo would only prove the decoder matches that encoder — it
# would pass just as happily with `rent_collector` and `members` in the wrong
# order, because both sides would be wrong together.
#
# The expected values below were produced INDEPENDENTLY, by
# `@sqds/multisig`'s own `Multisig.fromAccountAddress` against the same
# account. Two decoders, one account, agreeing field for field.
#
# ── AND THE NUMBERS THEMSELVES MATTERED ──────────────────────────────────────
#
# Three places in this repo stated this multisig's membership and threshold and
# all three disagreed: `Solana::Config` said "FOUR at threshold 3", the admin
# hub tile said "2-of-3", `docs/SOLANA.md` said five at three. The chain says
# THREE OF FIVE. That is why the page reads rather than quotes, and why the
# decoder is pinned here rather than trusted.
class Solana::SquadsTest < ActiveSupport::TestCase
  THRESHOLD = 3
  CREATE_KEY = "HCQWKXq5wPeY8YeFyzzfzW7yXyBctNjz77rXuNPAFqi5".freeze
  MEMBERS = %w[
    2eGs8G3wzhEeNQQU2Q86BmmA2xTpDbMMae3Y1bvpZfx9
    3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA
    7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr
    8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd
    BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo
  ].freeze
  MULTISIG = "7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB".freeze
  VAULT_PDA_0 = "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC".freeze

  def raw
    @raw ||= Base64.decode64(
      Rails.root.join("test/fixtures/files/squads_multisig_devnet.b64").read.strip
    )
  end

  def decoded
    @decoded ||= Solana::Squads.decode(raw)
  end

  # Byte offsets DERIVED from the decoder's own constants rather than written
  # out, so a tampering test cannot quietly aim at the wrong byte and "pass"
  # because nothing changed. This fixture's `rent_collector` is None, so the
  # option costs exactly its one tag byte.
  #
  #   8 disc + 32 create_key + 32 config_authority + 2 threshold + 4 time_lock
  #   + 8 transaction_index + 8 stale_transaction_index = 94 (the tag offset)
  #   + 1 tag + 1 bump = 96, where the u32 member count begins.
  def member_count_offset
    Solana::Squads::RENT_COLLECTOR_TAG_OFFSET + 1 + 1
  end

  def members_offset
    member_count_offset + 4
  end

  def member_mask_offset(index)
    members_offset + index * Solana::Squads::MEMBER_LEN + 32
  end

  test "decodes the live devnet multisig as threshold 3 of 5" do
    assert_equal THRESHOLD, decoded[:threshold]
    assert_equal 5, decoded[:members].length
    assert_equal MEMBERS.sort, decoded[:members].map { |m| m[:address] }.sort
  end

  test "every member holds Initiate, Vote and Execute" do
    decoded[:members].each do |member|
      assert_equal 7, member[:mask], "#{member[:address]} should hold the full mask"
      assert member[:can_initiate]
      assert member[:can_vote]
      assert member[:can_execute]
    end
    assert_equal 5, decoded[:voting_members].length
  end

  test "decodes the header fields the member offsets depend on" do
    # These are not decoration. `rent_collector` is an Option<Pubkey>, so its
    # tag byte decides whether `members` begins 1 byte or 33 bytes later — get
    # it wrong and every member key shifts by 32 bytes and STILL DECODES, into
    # plausible-looking garbage. Asserting the header is what makes the member
    # assertions above mean something.
    assert_equal CREATE_KEY, decoded[:create_key]
    assert_equal 0, decoded[:time_lock]
    assert_nil decoded[:rent_collector]
    assert_equal 254, decoded[:bump]
  end

  test "permission bits are read per member, not assumed uniform" do
    # A member with vote stripped must not be counted toward the threshold.
    # Built by editing the real fixture's last member mask to 1 (Initiate only),
    # so only the bit under test changes.
    tampered = raw.dup
    tampered.setbyte(member_mask_offset(4), Solana::Squads::INITIATE)

    result = Solana::Squads.decode(tampered)
    stripped = result[:members].last

    assert_equal 1, stripped[:mask]
    assert stripped[:can_initiate]
    assert_not stripped[:can_vote]
    assert_not stripped[:can_execute]
    assert_equal 4, result[:voting_members].length,
                 "a member who cannot vote cannot help reach the threshold"
    assert_not_includes result[:voting_members], stripped[:address]
  end

  # ── THE VAULT PDA. Derived, never compared against the multisig address. ───

  test "vault PDA index 0 derives to the program's actual upgrade authority" do
    # `solana program show EQGF…bpMJ --url devnet` prints this address as the
    # Authority. It is a PDA OWNED BY the multisig, not the multisig account —
    # comparing the Authority line against MULTISIG never matches, and reads as
    # "the authority is wrong" when nothing is wrong. That mistake has been made
    # twice in this ecosystem.
    assert_equal VAULT_PDA_0, Solana::Squads.vault_pda(MULTISIG)
  end

  test "the vault PDA is NOT the multisig address" do
    assert_not_equal MULTISIG, Solana::Squads.vault_pda(MULTISIG)
  end

  test "a different vault index derives a different address" do
    assert_not_equal Solana::Squads.vault_pda(MULTISIG, index: 0),
                     Solana::Squads.vault_pda(MULTISIG, index: 1)
  end

  # ── REFUSALS ──────────────────────────────────────────────────────────────

  test "a truncated account is refused rather than half-decoded" do
    error = assert_raises(Solana::Squads::ReadError) do
      Solana::Squads.decode(raw.byteslice(0, 40))
    end
    assert_match(/truncated/, error.message)
  end

  test "a members vec longer than the account is refused" do
    # The bounds check that separates "this is a Squads account" from "these
    # four bytes happened to parse as a big number". Without it a malformed or
    # misidentified account would read 33 bytes per phantom member off the end.
    tampered = raw.dup
    tampered[member_count_offset, 4] = [9_999].pack("L<")

    error = assert_raises(Solana::Squads::ReadError) { Solana::Squads.decode(tampered) }
    assert_match(/members \(9999\)/, error.message)
  end

  test "a malformed rent_collector option tag is refused" do
    tampered = raw.dup
    tampered.setbyte(Solana::Squads::RENT_COLLECTOR_TAG_OFFSET, 7)

    error = assert_raises(Solana::Squads::ReadError) { Solana::Squads.decode(tampered) }
    assert_match(/rent_collector option tag/, error.message)
  end

  test "an account owned by another program is refused, not decoded" do
    client = Object.new
    client.define_singleton_method(:get_account_info) do |_address, **|
      { "value" => { "data" => [Base64.strict_encode64("x" * 600), "base64"],
                     "owner" => "11111111111111111111111111111111" } }
    end

    error = assert_raises(Solana::Squads::ReadError) do
      Solana::Squads.read!(address: MULTISIG, client: client)
    end
    assert_match(/not the Squads V4 program/, error.message)
  end

  test "an absent account is refused by read! and nil from read" do
    client = Object.new
    client.define_singleton_method(:get_account_info) { |_address, **| { "value" => nil } }

    assert_raises(Solana::Squads::ReadError) { Solana::Squads.read!(address: MULTISIG, client: client) }
    assert_nil Solana::Squads.read(address: MULTISIG, client: client)
  end

  test "read NEVER raises, so one failed authority cannot take the page down" do
    # The overview renders three authorities side by side. A transient RPC
    # failure on this one must not 500 the page an operator opens mid-incident.
    client = Object.new
    client.define_singleton_method(:get_account_info) { |_address, **| raise "connection reset" }

    assert_nothing_raised { assert_nil Solana::Squads.read(address: MULTISIG, client: client) }
  end

  # ── CLUSTER SELECTION ─────────────────────────────────────────────────────

  test "the multisig address is per cluster and mainnet is never the default" do
    assert_equal Solana::Config::MAINNET_SQUADS_MULTISIG, Solana::Config.squads_multisig("mainnet-beta")
    assert_equal Solana::Config::DEVNET_SQUADS_MULTISIG, Solana::Config.squads_multisig("devnet")
    # An unrecognised cluster gets DEVNET, for the same reason squads_vault_pda
    # does: the failure that matters is claiming mainnet authority somewhere it
    # does not apply.
    assert_equal Solana::Config::DEVNET_SQUADS_MULTISIG, Solana::Config.squads_multisig("localnet")
  end

  test "the Squads web link carries the cluster in its ADDRESS, not its host" do
    # `devnet.squads.so` is decommissioned, so there is no cluster-flavoured
    # host to switch to — app.squads.so serves both and resolves by address.
    devnet  = Solana::Config.squads_app_url("devnet")
    mainnet = Solana::Config.squads_app_url("mainnet-beta")

    assert_match %r{\Ahttps://app\.squads\.so/squads/}, devnet
    assert_match %r{\Ahttps://app\.squads\.so/squads/}, mainnet
    assert_not_equal devnet, mainnet
    assert_includes devnet, Solana::Config::DEVNET_SQUADS_MULTISIG
    assert_includes mainnet, Solana::Config::MAINNET_SQUADS_MULTISIG
    assert_not_includes devnet, "devnet.squads.so"
  end
end
