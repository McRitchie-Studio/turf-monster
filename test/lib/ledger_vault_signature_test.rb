require "test_helper"

# [unit] LedgerVault takes the arguments Solana::Vault takes.
#
# The entry tests prove "one spend" through this double, so a keyword the
# service misspells must fail THERE as it would in production. A double that
# accepted `**kwargs`, or named a keyword differently, would let that through.
# Positional names are free to differ; arity, kind and every keyword name are not.
class LedgerVaultSignatureTest < ActiveSupport::TestCase
  ENTRY_PATH_METHODS = %i[
    enter_contest_with_token enter_contest_with_usdc next_free_entry_index ensure_user_account
    fetch_wallet_balances list_entry_tokens entry_pda sync_balance seeds_for_entry
  ].freeze

  def shape(klass, name)
    klass.instance_method(name).parameters.map do |kind, param|
      %i[req opt rest].include?(kind) ? [kind] : [kind, param]
    end
  end

  ENTRY_PATH_METHODS.each do |name|
    test "#{name} has the real method's parameter list" do
      assert_equal LedgerVault, LedgerVault.instance_method(name).owner, "#{name} must be defined on LedgerVault itself"
      assert_equal shape(Solana::Vault, name), shape(LedgerVault, name)
    end
  end

  test "no entry-path method swallows unknown keywords" do
    ENTRY_PATH_METHODS.each do |name|
      kinds = LedgerVault.instance_method(name).parameters.map(&:first)
      assert_not_includes kinds, :keyrest, "#{name} takes **kwargs, which hides a misspelt keyword"
    end
  end

  test "a misspelt keyword is refused" do
    vault = LedgerVault.new(tokens: [{ pda: "t1", consumed: false }])
    assert_raises(ArgumentError) do
      vault.enter_contest_with_token("wallet", "slug", 0, "t1", keypair: "k", season_id: 1)
    end
  end
end
