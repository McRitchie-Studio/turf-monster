require "test_helper"

# Integration — LevelUpTokenMintJob across its real I/O boundary: the SQL
# candidate query, the Solana RPC seam (FakeVault), and the DB waterline write.
#
# The job powers both the immediate post-level-up nudge and the recovery sweep,
# so the properties under test are the ones an operator would be paged about:
# does it pay promptly, find the right users, cost nothing when idle, survive
# one bad wallet, and avoid paying twice.
class LevelUpTokenMintJobTest < ActiveJob::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture
    epoch = Time.utc(1970, 1, 1)
    @user.update_columns(
      seeds: 0, level: 1, entry_tokens_granted_level: 1, entry_tokens_swept_at: epoch
    )
    User.where.not(id: @user.id).update_all(
      level: 1, entry_tokens_granted_level: 1, entry_tokens_swept_at: epoch
    )
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

  # --- immediate level-up nudge ---

  test "a fresh milestone snapshot updates the mirror and enqueues a targeted run" do
    store = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, store) do
      assert_enqueued_with(job: LevelUpTokenMintJob, args: [{ user_id: @user.id }]) do
        assert LevelUpTokenMintJob.nudge(@user, seeds_total: 100)
      end
    end

    assert_equal 2, @user.reload.level
  end

  test "repeated milestone snapshots coalesce while the targeted run is outstanding" do
    store = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, store) do
      assert_enqueued_jobs 1 do
        assert LevelUpTokenMintJob.nudge(@user, seeds_total: 100)
        assert_not LevelUpTokenMintJob.nudge(@user, seeds_total: 100)
      end
    end
  end

  test "a cache outage fails open and still enqueues the payout" do
    unavailable_cache = Object.new
    unavailable_cache.define_singleton_method(:write) { |*, **| nil }

    Rails.stub(:cache, unavailable_cache) do
      assert_enqueued_with(job: LevelUpTokenMintJob, args: [{ user_id: @user.id }]) do
        assert LevelUpTokenMintJob.nudge(@user, seeds_total: 100)
      end
    end
  end

  test "a settled milestone does not enqueue another targeted run" do
    @user.update_columns(seeds: 100, level: 2, entry_tokens_granted_level: 2)

    assert_no_enqueued_jobs do
      assert_not LevelUpTokenMintJob.nudge(@user, seeds_total: 100)
    end
  end

  test "a targeted run verifies live seeds and mints without waiting for the sweep mirror" do
    # The entry response sees the fresh on-chain total before the denormalized
    # users.level mirror has necessarily caught up. The immediate path must be
    # able to name the user directly and let LevelUpGrant re-read chain truth;
    # otherwise this reward waits for a later hydrate + 15-minute sweep.
    vault = vault_for(seeds: 100)

    run_sweep(vault, user_id: @user.id)

    assert_equal ["levelup:#{@user.id}:2"], vault.mint_calls
    assert_equal 2, @user.reload.entry_tokens_granted_level
  end

  # --- the candidate query ---

  test "the recovery schedule identifies every Rails worker as Active Job" do
    schedule = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))

    schedule.each do |name, config|
      next unless config.fetch("class").constantize < ActiveJob::Base

      assert_equal true, config.fetch("active_job"),
        "#{name}: sidekiq-cron otherwise calls perform_async on ActiveJob::ConfiguredJob"
    end
  end

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

    assert_empty vault.sync_balance_calls, "the candidate query must not touch chain balances"
    assert_empty vault.entry_token_list_calls, "the candidate query must not scan entry tokens"
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

    assert_difference "ErrorLog.count", 2 do
      assert_nothing_raised { run_sweep(vault) }
    end

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

  test "busts both real cache layers so the navbar badge repaints" do
    @user.update_columns(seeds: 100, level: 2)
    store = ActiveSupport::Cache::MemoryStore.new
    user_key = @user.entry_tokens_cache_key
    vault_key = Solana::Vault.entry_tokens_cache_key(@user.solana_address)

    Rails.stub(:cache, store) do
      Rails.cache.write(user_key, [{ consumed: false }])
      Rails.cache.write(vault_key, [{ consumed: false }])

      run_sweep(vault_for(seeds: 100))

      assert_nil Rails.cache.read(user_key), "the User wrapper cache must be cold"
      assert_nil Rails.cache.read(vault_key),
        "the navbar reads the Vault cache directly; leaving it warm hides the new token"
    end
  end

  test "an unevaluable oldest user is alerted and rotates behind the next candidate" do
    @user.update_columns(seeds: 100, level: 2)
    later = User.create!(
      email: "later-level-up@example.com",
      web3_solana_address: Solana::Keypair.generate.address,
      seeds: 100,
      level: 2,
      entry_tokens_granted_level: 1,
      entry_tokens_swept_at: Time.utc(1970, 1, 1)
    )
    missing_address = @user.solana_address
    vault = vault_for(seeds: 100)
    original_sync = vault.method(:sync_balance)
    vault.define_singleton_method(:sync_balance) do |address|
      address == missing_address ? nil : original_sync.call(address)
    end

    assert_difference "ErrorLog.count", 1 do
      run_sweep(vault, batch_size: 1)
    end

    alert = ErrorLog.order(:id).last
    assert_equal @user, alert.target
    assert_match(/unevaluable user=#{@user.id}/, alert.message)
    assert_operator @user.reload.entry_tokens_swept_at, :>, Time.utc(1970, 1, 1)
    assert_empty vault.mint_calls, "the first pass reached no payout verdict"

    run_sweep(vault, batch_size: 1)

    assert_equal ["levelup:#{later.id}:2"], vault.mint_calls,
      "the stuck low-id row must not occupy the bounded batch again"
    assert_equal 1, @user.reload.entry_tokens_granted_level,
      "rotation must never pretend the unevaluable user was paid"
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
