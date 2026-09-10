require "test_helper"

# [unit] The wallet-resolution RULE itself, exercised directly rather than
# through a request.
#
# WHY A UNIT TIER AT ALL, when ramp_sessions_controller_test already drives this
# end to end: that suite proves the rule through a POST, a stubbed CDP client and
# a persisted row, so a failure there could be any of four things. This isolates
# the one decision — given a session and a user, WHICH ADDRESS — so a regression
# names itself. It is also the tier that can enumerate the shapes cheaply: the
# request tier needs a full round trip per case.
#
# The rule under test: BOTH directions ask the SESSION, never account identity.
# The onramp used to take User#solana_address unconditionally (web3-preferred),
# which credited Phantom for a combo account whose entry pays from the managed
# wallet.
class Cdp::WalletForResolutionTest < ActiveSupport::TestCase
  WEB3 = "PhantomAddrFixed1111111111111111111111111".freeze
  WEB2 = "ManagedAddrFixed11111111111111111111111".freeze

  # A stand-in for the controller with only what #wallet_for reads. Calling the
  # real private method keeps this a test of the SHIPPING code, not a copy of it.
  class Subject < Cdp::RampSessionsController
    def initialize(user:, web3_session:)
      @user = user
      @web3_session = web3_session
    end
    def current_user = @user
    def wallet_context = Struct.new(:web3).new(@web3_session).then { |c| def c.web3? = web3; c }
    public :wallet_for
  end

  def resolve(direction, web3:, web2:, web3_session:)
    user = User.new(web3_solana_address: web3, web2_solana_address: web2)
    Subject.new(user: user, web3_session: web3_session).wallet_for(direction)
  end

  # --- the defect this closed -------------------------------------------------

  test "combo account on a web2 session resolves the MANAGED wallet, both directions" do
    %i[onramp offramp].each do |direction|
      address, mode = resolve(direction, web3: WEB3, web2: WEB2, web3_session: false)
      assert_equal WEB2, address,
                   "#{direction}: a web2 session pays its entry from the managed " \
                   "wallet, so crediting Phantom strands the money"
      assert_equal :web2, mode
    end
  end

  test "combo account on a Phantom session resolves the web3 wallet, both directions" do
    %i[onramp offramp].each do |direction|
      address, mode = resolve(direction, web3: WEB3, web2: WEB2, web3_session: true)
      assert_equal WEB3, address, "#{direction}: this session can sign with Phantom"
      assert_equal :web3, mode
    end
  end

  # --- symmetry, stated as its own property -----------------------------------

  test "onramp and offramp never disagree for one session" do
    [[WEB3, WEB2], [nil, WEB2], [WEB3, nil]].each do |web3, web2|
      [true, false].each do |web3_session|
        on  = resolve(:onramp,  web3: web3, web2: web2, web3_session: web3_session)
        off = resolve(:offramp, web3: web3, web2: web2, web3_session: web3_session)
        next if web3.present? && web2.blank? && !web3_session # the documented onramp-only fallback

        assert_equal off, on,
                     "money in and money out must name the same wallet " \
                     "(web3=#{web3.inspect} web2=#{web2.inspect} session_web3=#{web3_session})"
      end
    end
  end

  # --- the edges --------------------------------------------------------------

  test "managed-only account resolves the managed wallet whatever the session claims" do
    [true, false].each do |web3_session|
      address, mode = resolve(:onramp, web3: nil, web2: WEB2, web3_session: web3_session)
      assert_equal WEB2, address, "there is no Phantom to prefer"
      assert_equal :web2, mode
    end
  end

  # The `direction == :onramp` guard on that fallback is the ONE token in this
  # method whose removal the rest of this file cannot see: dropping it reads like
  # a simplification (the branch looks redundant) and leaves every other test
  # green. It is not redundant. An offramp SOURCES funds, so it needs a wallet
  # this session can SIGN with; a web2 session cannot sign for Phantom. Falling
  # back there would mint a session token and open a cash-out the user can never
  # complete, instead of the honest refusal create_session renders from a blank
  # address. The symmetry property above deliberately skips this shape, so this
  # is the only test that pins it.
  test "the onramp-only fallback does NOT leak into the offramp" do
    address, mode = resolve(:offramp, web3: WEB3, web2: nil, web3_session: false)
    assert_nil address, "an offramp needs a signer, and this session has none"
    assert_equal :web2, mode
  end

  test "web3-only account on a web2 session still gets an onramp destination" do
    # Refusing would strand the deposit; a deposit into the account's own only
    # wallet is never unsafe, merely less useful than it could be.
    address, mode = resolve(:onramp, web3: WEB3, web2: nil, web3_session: false)
    assert_equal WEB3, address
    assert_equal :web3, mode
  end
end
