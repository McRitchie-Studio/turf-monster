require "test_helper"

# Integration — LevelUpTokenMintJob across its real I/O boundary: the SQL
# candidate query, the Solana RPC seam (FakeVault), and the DB waterline write.
#
# The job is the thing that makes the level-up modal's "arrives in 48 hours"
# true, so the properties under test are the ones an operator would be paged
# about: does it find the right users, does it cost nothing when idle, does it
# survive one bad wallet, and can it ever pay twice.
class LevelUpTokenMintJobTest < ActiveJob::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture
    @user.update_columns(seeds: 0, level: 1, entry_tokens_granted_level: 1)
    User.where.not(id: @user.id).update_all(level: 1, entry_tokens_granted_level: 1)
  end

  def token(source_ref)
    { pda: "pda-#{source_ref}", source_ref: source_ref, source: 0, consumed: false }
  end

  def vault_for(seeds:, tokens: [], fail_after: nil)
    FakeVault.new(tokens: tokens, fail_after: fail_after).tap { |v| v.sync_balance_seeds = seeds }
  end

  # Runs the job with both Solana seams closed: the instance the sweep builds
  # AND the class-level stale-env guard, which is a real network call.
  def run_sweep(vault, **kwargs)
    Solana::Vault.stub :ensure_program_id_live!, :live do
      Solana::Vault.stub :new, vault do
        LevelUpTokenMintJob.perform_now(**kwargs)
      end
    end
  end

  # --- the candidate query ---

  test "sweeps a user whose level has outrun their granted level" do
    @user.update_columns(seeds: 100, level: 2)
    vault = vault_for(seeds: 100)

    run_sweep(vault)

    assert_equal ["levelup:#{@user.id}:2"], vault.mint_calls
    assert_equal 2, @user.reload.entry_tokens_granted_level
  end

  test "costs ZERO Solana RPCs when no one has levelled up" do
    # The whole point of the denormalized filter: a cron running every 15
    # minutes must not pay two RPCs per levelled user to rediscover an empty
    # queue. If this ever fails, the sweep is scanning the chain on a timer.
    vault = vault_for(seeds: 500) # would owe 5 tokens IF it were ever consulted

    run_sweep(vault)

    assert_empty vault.mint_calls, "no candidate must mean no chain traffic at all"
  end

  test "ignores a levelled user who has already been granted through that level" do
    @user.update_columns(seeds: 100, level: 2, entry_tokens_granted_level: 2)
    vault = vault_for(seeds: 100)

    run_sweep(vault)

    assert_empty vault.mint_calls
  end

  test "skips wallet-less users entirely" do
    jordan = users(:jordan) # no solana address
    jordan.update_columns(seeds: 300, level: 4, entry_tokens_granted_level: 1)
    vault = vault_for(seeds: 300)

    run_sweep(vault)

    assert_empty vault.mint_calls, "there is nowhere to mint a token to"
    assert_not_includes LevelUpTokenMintJob.candidates.map(&:id), jordan.id
  end

  test "candidate query is bounded by the batch size" do
    @user.update_columns(seeds: 100, level: 2)
    vault = vault_for(seeds: 100)

    run_sweep(vault, batch_size: 0)

    assert_empty vault.mint_calls, "batch_size must actually bound the sweep"
  end

  # --- resilience ---

  test "one wallet's chain failure does not abort the sweep" do
    other = users(:alex)
    other.update_columns(
      web3_solana_address: "So11111111111111111111111111111111111111112",
      seeds: 100, level: 2, entry_tokens_granted_level: 1
    )
    @user.update_columns(seeds: 100, level: 2)

    # fail_after: 0 → EVERY mint raises. The sweep must still visit both users
    # and finish cleanly rather than propagating the first error.
    vault = vault_for(seeds: 100, fail_after: 0)

    assert_nothing_raised { run_sweep(vault) }

    assert_equal 2, vault.mint_calls.length, "both candidates must be attempted"
    assert_equal 1, @user.reload.entry_tokens_granted_level,
      "a failed mint must leave the user in the queue for the next run"
  end

  test "a failed sweep retries the same user on the next run" do
    @user.update_columns(seeds: 100, level: 2)

    run_sweep(vault_for(seeds: 100, fail_after: 0))
    assert_equal 1, @user.reload.entry_tokens_granted_level

    second = vault_for(seeds: 100)
    run_sweep(second)

    assert_equal ["levelup:#{@user.id}:2"], second.mint_calls, "the retry must land the grant"
    assert_equal 2, @user.reload.entry_tokens_granted_level
  end

  # --- the double-grant guard, end to end ---

  test "running the sweep twice never grants the same level twice" do
    @user.update_columns(seeds: 200, level: 3)

    first = vault_for(seeds: 200)
    run_sweep(first)
    assert_equal 2, first.mint_calls.length

    # Second run sees what the first minted, and the waterline has moved.
    second = vault_for(seeds: 200, tokens: first.mint_calls.map { |ref| token(ref) })
    run_sweep(second)

    assert_empty second.mint_calls, "the sweep must be idempotent across runs"
  end

  test "busts the entry-token cache so the navbar badge repaints" do
    @user.update_columns(seeds: 100, level: 2)
    cache_key = Solana::Vault.entry_tokens_cache_key(@user.solana_address)
    Rails.cache.write(cache_key, [], expires_in: 60.seconds)

    run_sweep(vault_for(seeds: 100))

    assert_nil Rails.cache.read(cache_key),
      "a stale cached token list would hide the token the user was just granted"
  ensure
    Rails.cache.delete(cache_key)
  end

  # --- the sweep must drain, not loop ---

  test "a user paid by a manual admin mint leaves the sweep for good" do
    # REGRESSION: the admin page mints with a RANDOM source_ref, which this
    # service cannot match by level. A waterline that only advanced over
    # level-matched refs left such a user permanently above the candidate line —
    # two RPCs every 15 minutes, forever, to rediscover that nothing is owed.
    @user.update_columns(seeds: 200, level: 3)
    admin_minted = token("operator:#{@user.id}:a1b2c3d4")

    first = vault_for(seeds: 200, tokens: [admin_minted])
    run_sweep(first)

    assert_equal 1, first.mint_calls.length, "1 of the 2 owed levels was already paid by hand"
    assert_not_includes LevelUpTokenMintJob.candidates.map(&:id), @user.id,
      "debt cleared — the user must drop out of the candidate query"

    second = vault_for(seeds: 200, tokens: [admin_minted, token(first.mint_calls.first)])
    run_sweep(second)

    assert_empty second.mint_calls, "a settled user must cost the next sweep nothing"
  end

  test "a user capped mid-backfill stays in the sweep until fully paid" do
    levels = Tokens::LevelUpGrant::MAX_GRANTS_PER_RUN + 2
    @user.update_columns(seeds: 100 * levels, level: levels + 1)

    first = vault_for(seeds: 100 * levels)
    run_sweep(first)

    assert_equal Tokens::LevelUpGrant::MAX_GRANTS_PER_RUN, first.mint_calls.length
    assert_includes LevelUpTokenMintJob.candidates.map(&:id), @user.id,
      "still owed — the remainder must be picked up next run"

    second = vault_for(seeds: 100 * levels, tokens: first.mint_calls.map { |ref| token(ref) })
    run_sweep(second)

    assert_equal 2, second.mint_calls.length, "the next run pays the deferred remainder"
    assert_not_includes LevelUpTokenMintJob.candidates.map(&:id), @user.id
  end

  # --- the stale-env guard ---

  test "refuses to mint against a PROGRAM_ID that does not exist on the RPC" do
    # The mint-to-wrong-program failure mode, which has bitten twice on devnet
    # redeploys. A cron must not quietly mint tokens into a dead program.
    @user.update_columns(seeds: 100, level: 2)
    vault = vault_for(seeds: 100)

    raiser = ->(*) { raise Solana::Vault::StaleEnvError, "stale env" }
    # `.new.perform`, not `perform_now`: ApplicationJob's `retry_on
    # StandardError` would catch the raise and re-enqueue, so perform_now
    # reports success and hides the guard. This asserts the guard itself.
    assert_raises(Solana::Vault::StaleEnvError) do
      Solana::Vault.stub :ensure_program_id_live!, raiser do
        Solana::Vault.stub :new, vault do
          LevelUpTokenMintJob.new.perform
        end
      end
    end

    assert_empty vault.mint_calls
  end
end
