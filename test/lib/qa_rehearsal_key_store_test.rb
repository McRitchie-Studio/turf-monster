# frozen_string_literal: true

require "test_helper"

# THIS FILE GUARDS A LOOKUP, NOT A KEY. KeyStore's whole job is to turn a cast
# slug into the right Solana::Keypair, and on 2026-09-15 two separate things
# about the 1Password side of that lookup changed underneath it at once:
#
#   * the Xan item (called "Alex Bot" until that day) was renamed
#     agent.xan.solana and MOVED to a vault this service account cannot read, so
#     the "alex" cast member became a pointer to nothing;
#   * agent.turf.solana was refiled — a SECOND item now carries that exact
#     title, and the newer one spells its labels with hyphens where the older
#     one used spaces.
#
# Those two break in opposite ways, and the second is the dangerous one. A
# dangling item is LOUD: `op` says it cannot find it. A duplicated title is loud
# too. But a renamed FIELD is SILENT — the old reader asked for "wallet address",
# got nil, and skipped the filed-address cross-check entirely. The guard that
# exists to catch a key filed under the wrong name would have switched itself
# off, on the one item whose filing had just changed, and reported success.
#
# So every test here is about the lookup's failure modes rather than about
# cryptography. None of them touch 1Password: the runner is injected, or
# Open3 is stubbed, and the keypairs are derived from a fixed non-secret seed.
class QaRehearsalKeyStoreTest < ActiveSupport::TestCase
  Store = TurfMonster::QaRehearsal::KeyStore

  # A deterministic, non-secret keypair. The Solana CLI keypair form is a JSON
  # byte array, which is also what agent.turf.solana files, so this doubles as
  # coverage of the array branch of `decode`.
  SEED = Digest::SHA256.digest("qa rehearsal key store test").freeze

  def keypair
    @keypair ||= Solana::Keypair.from_bytes(SEED)
  end

  def secret_json
    SEED.bytes.to_json
  end

  # A runner that answers with whatever fields the test wants to describe, and
  # records the item it was handed so the addressing can be asserted.
  def store_for(fields, seen: [])
    Store.new(runner: ->(item) { seen << item; fields })
  end

  # --- The cast --------------------------------------------------------

  # THE POINT OF THE REMOVAL, stated as a test so it cannot be undone by a
  # well-meaning repoint at agent.xan.solana. That item is real, but it lives in
  # studio-agents-admin, which this service account cannot open — and that
  # inaccessibility is the control that leaves an agent at 1-of-3 on both Squads
  # multisigs. Filing it here would trade a not-found for a permissions error
  # and invite someone to "fix" the permissions.
  test "no cast member points at the admin-vault Xan identity" do
    refute_includes Store::ITEMS.keys, "alex"
    refute_includes Store::ITEMS.keys, "xan"

    titles = Store::ITEMS.values.map(&:title)
    refute_includes titles, "agent.alex.solana",
                    "the renamed item is gone from 1Password; this is a dangling pointer"
    refute_includes titles, "agent.xan.solana",
                    "agent.xan.solana is in a vault this service account cannot read — " \
                    "pointing at it swaps a not-found for a permissions error"
  end

  test "every cast member reads from the vault this service account can open" do
    assert_equal "studio-agents", Store::VAULT
    assert_equal %w[mason mack turf turf-admin], Store::ITEMS.keys
  end

  # --- Addressing a title that is not unique ---------------------------

  # Two items in studio-agents carry the title "agent.turf.solana", so a title
  # read matches both and `op` refuses. The pin is what makes this cast member
  # resolvable at all, and it must be the ID that goes to `op`.
  test "turf-admin is addressed by its pinned 1Password id, not its title" do
    item = Store::ITEMS.fetch("turf-admin")

    assert_equal "agent.turf.solana", item.title
    assert_equal "mczgzinhh42mlltd6h4yvladhi", item.id
    assert_equal "mczgzinhh42mlltd6h4yvladhi", item.locator,
                 "a colliding title must reach op as an id or the read fails outright"
  end

  # The pin is the exception, not the house style: an ID documents nothing, so
  # the members whose titles are unique stay addressed by the readable name.
  test "members with unique titles are still addressed by title" do
    %w[mason mack turf].each do |who|
      item = Store::ITEMS.fetch(who)
      assert_nil item.id, "#{who} has no title collision and needs no id pin"
      assert_equal item.title, item.locator
    end
  end

  # --- The field labels ------------------------------------------------

  # The hyphenated filing is what agent.turf.solana uses now. Before
  # ADDRESS_FIELDS became a list this returned a keypair with the cross-check
  # silently skipped.
  test "a hyphenated filing is read, addresses included" do
    seen = []
    store = store_for({ "private-key" => secret_json, "wallet-address" => keypair.to_base58 },
                      seen: seen)

    assert_equal keypair.to_base58, store.address("turf-admin")
    assert_equal "mczgzinhh42mlltd6h4yvladhi", seen.first.locator
  end

  test "the older spaced filing is still read" do
    store = store_for({ "private key" => secret_json, "wallet address" => keypair.to_base58 })

    assert_equal keypair.to_base58, store.address("mason")
  end

  # THE CONTROL FOR THE TWO ABOVE. Reading the hyphenated item is only worth
  # asserting if the cross-check is actually RUNNING on it — a loader that
  # ignored the address field entirely would pass both of those tests. This one
  # files a key under a wallet address that is not its own and demands the
  # mismatch be caught, through the hyphenated labels.
  test "a key filed under the wrong address is caught through hyphenated labels" do
    other = Solana::Keypair.from_bytes(Digest::SHA256.digest("a different wallet entirely"))
    store = store_for({ "private-key" => secret_json, "wallet-address" => other.to_base58 })

    error = assert_raises(Store::KeyMismatchError) { store.keypair("turf-admin") }
    assert_match other.to_base58, error.message
    assert_match keypair.to_base58, error.message
  end

  # An absent address used to mean "skip the check". Every item this map can
  # reach files an address, so absence now means the label moved again — which
  # is precisely when the check must be loudest.
  test "a missing address field fails instead of skipping the cross-check" do
    store = store_for({ "private-key" => secret_json })

    error = assert_raises(Store::MissingKeyError) { store.keypair("turf-admin") }
    assert_match(/cross-check cannot run/, error.message)
    assert_match(/ADDRESS_FIELDS/, error.message)
  end

  # The pinned item also carries devnet-wallet-address / devnet-private-key —
  # a DIFFERENT wallet (2eGs8G3w…). turf-5's on-chain identity in QA is the
  # mainnet-labelled one, so those labels must never be picked up.
  test "the devnet pair on the same item is not a recognised filing" do
    refute_includes Store::SECRET_FIELDS, "devnet-private-key"
    refute_includes Store::ADDRESS_FIELDS, "devnet-wallet-address"

    store = store_for({ "devnet-private-key" => secret_json,
                        "devnet-wallet-address" => keypair.to_base58 })

    assert_raises(Store::MissingKeyError) { store.keypair("turf-admin") }
  end

  # --- Unknown cast ----------------------------------------------------

  test "an unfiled cast member names the ones that exist" do
    error = assert_raises(Store::MissingKeyError) { Store.new(runner: ->(_i) { {} }).keypair("alex") }

    assert_match(/no filed key for "alex"/, error.message)
    assert_match(/turf-admin/, error.message)
  end

  # --- The op boundary (integration) -----------------------------------

  def stub_op(stdout: "", stderr: "", ok: false, argv: [])
    status = Minitest::Mock.new
    status.expect(:success?, ok)
    Open3.stub(:capture3, ->(*args) { argv.replace(args); [stdout, stderr, status] }) { yield }
  end

  # The real read, with only the subprocess mocked: the id must reach the `op`
  # argv, or the pin is decorative.
  test "the pinned id is what reaches the op command line" do
    argv = []
    body = {
      "fields" => [
        { "label" => "private-key", "value" => secret_json },
        { "label" => "wallet-address", "value" => keypair.to_base58 }
      ]
    }.to_json

    result = stub_op(stdout: body, ok: true, argv: argv) do
      Store.new.keypair("turf-admin")
    end

    assert_equal keypair.to_base58, result.to_base58
    assert_equal %w[op item get mczgzinhh42mlltd6h4yvladhi --vault studio-agents --format json], argv
  end

  # A colliding title is the failure this whole pin exists to prevent, and if it
  # ever reappears the error must name the remedy. Left as a bare op failure it
  # reads like a missing item or a throttle and sends the reader to the wrong fix.
  test "a colliding title raises an error naming the pin as the remedy" do
    error = stub_op(stderr: '[ERROR] More than one item matches "agent.turf.solana"') do
      assert_raises(Store::AmbiguousItemError) { Store.new.keypair("turf-admin") }
    end

    assert_match(/agent\.turf\.solana/, error.message)
    assert_match(/Pin the one this cast member means by id/, error.message)
    refute_match(/op read failed/, error.message,
                 "an ambiguity reported as a generic read failure sends the reader to the wrong remedy")
  end

  # Anything else still surfaces 1Password's own stderr: a throttle and a
  # missing item want different responses, and only op knows which it was.
  test "any other op failure still surfaces 1Password's own stderr" do
    error = stub_op(stderr: "[ERROR] rate-limited: too many requests") do
      assert_raises(Store::MissingKeyError) { Store.new.keypair("mason") }
    end

    assert_match(/op read failed for agent\.mason\.solana/, error.message)
    assert_match(/rate-limited/, error.message)
  end
end
