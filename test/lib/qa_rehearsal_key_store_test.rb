# frozen_string_literal: true

require "test_helper"

# THIS FILE GUARDS A LOOKUP, NOT A KEY. KeyStore's whole job is to turn a cast
# slug into the right Solana::Keypair, and the 1Password side of that lookup has
# now broken in three different ways in as many days:
#
#   * a TITLE COLLIDED. Two items carried the exact title "agent.turf.solana",
#     so a title read matched both and `op` refused outright.
#   * the ANSWER TO THAT COLLIDED TOO. The fix was an id pin,
#     mczgzinhh42mlltd6h4yvladhi — and on 2026-09-15 that item was RECREATED
#     under a unique, role-specific title. A recreated item gets a new id, so
#     the pin resolved to nothing and every turf-admin read failed.
#   * a FIELD LABEL MOVED, silently. The refiled item spells its labels with
#     hyphens where the older ones used spaces.
#
# The third is the dangerous one, and it is why the cross-check is fatal on an
# absent address. A dangling item is LOUD: `op` says it cannot find it. A
# duplicated title is loud too. But a renamed FIELD was SILENT — the old reader
# asked for "wallet address", got nil, and skipped the filed-address cross-check
# entirely. The guard that exists to catch a key filed under the wrong name
# would have switched itself off, on the one item whose filing had just changed,
# and reported success.
#
# So every test here is about the lookup's failure modes rather than about
# cryptography. None of them touch 1Password: the runner is injected, or Open3
# is stubbed, and the keypairs are derived from a fixed non-secret seed.
class QaRehearsalKeyStoreTest < ActiveSupport::TestCase
  Store = TurfMonster::QaRehearsal::KeyStore

  # A deterministic, non-secret keypair. `secret_json` exercises the Solana-CLI
  # byte-array branch of `decode`; `secret_base58` exercises the branch every
  # item in the vault actually uses as of 2026-09-15. Both branches are live
  # code, so both are covered here.
  SEED = Digest::SHA256.digest("qa rehearsal key store test").freeze

  # The id that turf-admin was pinned to until 2026-09-15, kept here ONLY so a
  # test can prove it never reaches `op` again. See the no-id-pin test below.
  DEAD_ID = "mczgzinhh42mlltd6h4yvladhi"

  def keypair
    @keypair ||= Solana::Keypair.from_bytes(SEED)
  end

  def secret_json
    SEED.bytes.to_json
  end

  # Solana::Keypair has no secret-side base58 reader — `to_base58` is the PUBLIC
  # key. The encoder is a class method, and this is the only way to produce the
  # exact on-disk form the vault files.
  def secret_base58
    Solana::Keypair.encode_base58(keypair.to_bytes)
  end

  # A runner that answers with whatever fields the test wants to describe, and
  # records the item it was handed so the addressing can be asserted.
  def store_for(fields, seen: [])
    Store.new(runner: ->(item) { seen << item; fields })
  end

  # --- The cast --------------------------------------------------------

  # THE POINT OF THE REMOVAL, stated as a test so it cannot be undone by a
  # well-meaning repoint at agent.xan.solana. That item is real, but it lives in
  # studio-agents-admin, which this service account cannot open. Filing it here
  # would trade a not-found for a permissions error and invite someone to "fix"
  # the permissions.
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

  # --- Addressing: by title, never by id -------------------------------

  # THE REGRESSION TEST FOR THE OUTAGE. turf-admin was pinned to an item id;
  # the item was recreated under a new title, the id died with the old object,
  # and the lookup failed outright with a bare not-found.
  test "turf-admin is addressed by its unique title" do
    item = Store::ITEMS.fetch("turf-admin")

    assert_equal "solana.turf.admin", item.title
    assert_nil item.id
    assert_equal "solana.turf.admin", item.locator,
                 "the title is unique in studio-agents; an id pin would die on the next re-file"
  end

  # NO SLUG MAY CARRY AN ID PIN, and the reason is stronger than "the last one
  # died". `op item get <id>` resolves directly and can NEVER report "more than
  # one item matches", so an id pin makes AmbiguousItemError unreachable for
  # that slug. Pinning by title is what keeps that guard armed — the collision
  # test at the bottom of this file is only meaningful while this holds.
  test "no cast member is addressed by an id" do
    Store::ITEMS.each do |who, item|
      assert_nil item.id,
                 "#{who} carries an id pin, which disarms AmbiguousItemError for that slug"
      assert_equal item.title, item.locator
    end

    refute_includes Store::ITEMS.values.map(&:id), DEAD_ID
  end

  # --- The field labels ------------------------------------------------

  # The hyphenated filing is what all three solana.turf.* items use. Before
  # ADDRESS_FIELDS became a list this returned a keypair with the cross-check
  # silently skipped.
  test "a hyphenated filing is read, addresses included" do
    seen = []
    store = store_for({ "private-key" => secret_base58, "wallet-address" => keypair.to_base58 },
                      seen: seen)

    assert_equal keypair.to_base58, store.address("turf-admin")
    assert_equal "solana.turf.admin", seen.first.locator
  end

  test "the older spaced filing is still read" do
    store = store_for({ "private key" => secret_base58, "wallet address" => keypair.to_base58 })

    assert_equal keypair.to_base58, store.address("mason")
  end

  # Both encodings stay live code. Every item in the vault files base58 today,
  # but this vault was restructured three times in one day, so the byte-array
  # branch is kept and therefore has to be covered.
  test "a Solana-CLI byte array is decoded as well as base58" do
    store = store_for({ "private-key" => secret_json, "wallet-address" => keypair.to_base58 })

    assert_equal keypair.to_base58, store.address("turf-admin")
  end

  # THE CONTROL FOR THE THREE ABOVE. Reading the hyphenated item is only worth
  # asserting if the cross-check is actually RUNNING on it — a loader that
  # ignored the address field entirely would pass all of those. This one files a
  # key under a wallet address that is not its own and demands the mismatch be
  # caught, through the hyphenated labels.
  test "a key filed under the wrong address is caught through hyphenated labels" do
    other = Solana::Keypair.from_bytes(Digest::SHA256.digest("a different wallet entirely"))
    store = store_for({ "private-key" => secret_base58, "wallet-address" => other.to_base58 })

    error = assert_raises(Store::KeyMismatchError) { store.keypair("turf-admin") }
    assert_match other.to_base58, error.message
    assert_match keypair.to_base58, error.message
  end

  # An absent address used to mean "skip the check". Every item this map can
  # reach files an address, so absence now means the label moved again — which
  # is precisely when the check must be loudest.
  test "a missing address field fails instead of skipping the cross-check" do
    store = store_for({ "private-key" => secret_base58 })

    error = assert_raises(Store::MissingKeyError) { store.keypair("turf-admin") }
    assert_match(/cross-check cannot run/, error.message)
    assert_match(/ADDRESS_FIELDS/, error.message)
  end

  # The devnet wallet (2eGs8G3w…) used to ride along on the SAME item as the
  # admin key, under devnet-* labels, and picking it up would have signed as an
  # account the app has never heard of. It is now its own item
  # (solana.turf.system.devnet) — but the exclusion stays asserted, because it
  # costs nothing and it is what keeps the guarantee if the pair is ever
  # recombined the way it was before.
  test "a devnet-labelled pair is not a recognised filing" do
    refute_includes Store::SECRET_FIELDS, "devnet-private-key"
    refute_includes Store::ADDRESS_FIELDS, "devnet-wallet-address"

    store = store_for({ "devnet-private-key" => secret_base58,
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

  # The real read, with only the subprocess mocked: the TITLE must reach the
  # `op` argv. The dead id must not appear anywhere in it — that exact argv,
  # built from a pin to a recreated item, is what failed in production.
  test "the title is what reaches the op command line" do
    argv = []
    body = {
      "fields" => [
        { "label" => "private-key", "value" => secret_base58 },
        { "label" => "wallet-address", "value" => keypair.to_base58 }
      ]
    }.to_json

    result = stub_op(stdout: body, ok: true, argv: argv) do
      Store.new.keypair("turf-admin")
    end

    assert_equal keypair.to_base58, result.to_base58
    assert_equal %w[op item get solana.turf.admin --vault studio-agents --format json], argv
    refute_includes argv, DEAD_ID
  end

  # A colliding title is the failure the removed id pin existed to prevent, and
  # addressing by title is what keeps this path REACHABLE at all. Left as a bare
  # op failure it reads like a missing item or a throttle and sends the reader
  # to the wrong fix.
  test "a colliding title raises an error naming the pin as the remedy" do
    error = stub_op(stderr: '[ERROR] More than one item matches "solana.turf.admin"') do
      assert_raises(Store::AmbiguousItemError) { Store.new.keypair("turf-admin") }
    end

    assert_match(/solana\.turf\.admin/, error.message)
    assert_match(/Pin the one this cast member means by id/, error.message)
    refute_match(/op read failed/, error.message,
                 "an ambiguity reported as a generic read failure sends the reader to the wrong remedy")
  end

  # A dead pin is the OTHER failure, and it must not masquerade as a collision.
  # `op` reports a missing item as an ordinary failure, so this has to land on
  # MissingKeyError carrying 1Password's own words.
  test "an item that no longer exists surfaces as a missing key, not an ambiguity" do
    error = stub_op(stderr: "[ERROR] \"#{DEAD_ID}\" isn't an item in the studio-agents vault") do
      assert_raises(Store::MissingKeyError) { Store.new.keypair("turf-admin") }
    end

    assert_match(/op read failed for solana\.turf\.admin/, error.message)
    assert_match(/isn't an item/, error.message)
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
