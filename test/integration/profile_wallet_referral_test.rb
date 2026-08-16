require "test_helper"

# [integration] The Solana wallet and referral cards, on BOTH pages.
#
# THE MIGRATION THESE BELONG TO. /profile is this app's new account page and
# /account is being emptied onto it a card at a time. These two cards are the
# web3 half of that, and the thing worth pinning is not "they render" but that
# they render from ONE partial in TWO places — the whole point of moving them
# this way rather than copying the markup across.
#
# WHY INTEGRATION AND NOT A VIEW TEST. Both cards used to read CONTROLLER STATE:
# the referral card read @referral_share_contest, which only AccountsController
# assigns, and the wallet block read @user. A partial that depends on its
# caller's ivars renders fine in a view test — you hand it whatever it asks for —
# and then 500s or silently renders empty on the page that does not set them.
# Only a real request through the ENGINE's controller proves the dependency is
# actually cut, because that controller has never heard of either ivar.
class ProfileWalletReferralTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
  end

  # This app's real sign-in, driven end to end — there is no test-only login
  # route, and a session needs BOTH session[:user_id] and session[:session_token]
  # (verify_session_token compares the cookie's token on every request). It
  # ASSERTS it worked: a setup step that can quietly do nothing would leave every
  # assertion below running signed out, where /profile redirects and every
  # refute_ passes for the wrong reason.
  def sign_in_as(user)
    link = Studio::Link.create_magic_link(email: user.email, return_to: "/", ttl: 1.hour)
    get "/l/#{link.token}"
    post "/l/#{link.token}"

    get "/account"
    assert_response :success, "sign-in did not take — every assertion below would run signed out"
  end

  def connect_wallet(user)
    user.update!(web3_solana_address: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")
  end

  # --- the rows are registered -------------------------------------------------

  test "both cards are declared on the profile page" do
    keys = Studio.profile_sections.call(nil).map { |section| section[:key].to_sym }

    assert_includes keys, :solana_wallet
    assert_includes keys, :referral
  end

  # THE REFERRAL ROW MUST NOT DECLARE A TITLE. Its own header carries the info
  # toggle and the three share targets; a row title would render an h2 above it
  # and the card would be headed twice.
  test "the referral row leaves its heading to the partial" do
    row = Studio.profile_sections.call(nil).find { |section| section[:key] == :referral }

    assert_nil row[:title], "a row title here would sit above the card's own header"
  end

  # --- the wallet card ---------------------------------------------------------

  test "the wallet card renders on the profile page" do
    connect_wallet(@user)
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="solana_wallet"'
    assert_includes response.body, @user.reload.solana_address,
      "the address did not render — the partial is not seeing the user it was passed"
  end

  # ALL FIVE TILES, by name. The card is five balances and three buttons; a
  # response that carried the section wrapper and none of its contents would
  # satisfy a laxer assertion while showing an empty card.
  test "the wallet card carries its five balances and three actions" do
    connect_wallet(@user)
    sign_in_as(@user)
    get "/profile"

    %w[USDC USDT SOL].each { |label| assert_includes response.body, label }
    assert_match(/entry tokens/i, response.body)
    assert_match(/seeds/i, response.body)

    assert_match(/Buy USDC/i, response.body)
    assert_match(/Refresh Wallet/i, response.body)
  end

  # THE NOT-CONNECTED BRANCH IS A CONNECT BUTTON, not an absent card — which is
  # exactly why the gate lives inside the partial rather than in the row's `if:`.
  # A row-level gate would drop the card here and leave this account no way to
  # link a wallet from this page.
  test "an account with no wallet is offered one on the profile page" do
    @user.update!(web3_solana_address: nil)
    refute @user.reload.solana_connected?, "the fixture still has a wallet — this test proves nothing"

    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="solana_wallet"',
      "the row vanished for an account with no wallet — the connect button went with it"
  end

  # --- the referral card -------------------------------------------------------

  # THE IVAR THAT HAD TO GO. This card read @referral_share_contest, assigned only
  # by AccountsController. The engine's ProfilesController does not set it and
  # cannot be made to, so the partial resolves its own default — and this is the
  # test that says so, by rendering it through that controller.
  test "the referral card renders on the profile page without its old controller ivar" do
    sign_in_as(@user)
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="referral"'
    assert_match(/Get a Free Entry/i, response.body)
    assert_includes response.body, "Copy Link"
  end

  test "the referral link points at the shared contest" do
    sign_in_as(@user)
    get "/profile"

    assert_match %r{/l/}, response.body,
      "no referral link rendered — referral_link_url resolved to nothing"
  end

  # --- one implementation, two pages -------------------------------------------

  # THE CLAIM THE WHOLE CHANGE RESTS ON. Copying the markup would satisfy every
  # assertion above and drift within a month, so this asserts the SOURCE: both
  # pages render the same partial by name, and neither reimplements it.
  test "both pages render the same two partials rather than copies" do
    account = Rails.root.join("app/views/accounts/show.html.erb").read

    assert_includes account, 'render "accounts/solana_wallet_section"'
    assert_includes account, 'render "accounts/referral_section"'

    rows = Studio.profile_sections.call(nil)
    assert_equal "accounts/solana_wallet_section",
                 rows.find { |s| s[:key] == :solana_wallet }[:partial]
    assert_equal "accounts/referral_section",
                 rows.find { |s| s[:key] == :referral }[:partial]

    refute_includes account, "data-wallet-tile",
      "the wallet tiles are back inline on /account — that is the copy this change removed"
    refute_includes account, "@referral_share_contest",
      "the referral ivar is back on /account — the partial resolves its own contest now"
  end

  # NEITHER PARTIAL MAY READ CONTROLLER STATE. This is the property that makes
  # them renderable from the engine at all, and it is invisible on /account —
  # where every ivar it might reach for happens to be set. Asserted on the source
  # because a passing render on one page cannot distinguish "does not use it"
  # from "used it and it was there".
  test "neither partial reaches for an ivar or current_user" do
    %w[_solana_wallet_section _referral_section].each do |name|
      source = Rails.root.join("app/views/accounts/#{name}.html.erb").read
      markup = source.gsub(/<%#.*?%>/m, "")

      refute_match(/@[a-z_]+[^a-zA-Z_(]/, markup.gsub(/@(click|keydown|change|submit|input|blur|focus)/, ""),
        "#{name} reads a controller instance variable — it renders on /account, where that " \
        "ivar happens to be set, and silently empties on /profile where it is not")
      refute_includes markup, "current_user",
        "#{name} reads current_user from the view context instead of the user: local it is passed"
    end
  end

  # --- /account did not regress ------------------------------------------------

  test "both cards still render on the account page" do
    connect_wallet(@user)
    sign_in_as(@user)
    get "/account"

    assert_response :success
    assert_includes response.body, @user.reload.solana_address
    assert_match(/Get a Free Entry/i, response.body)
    assert_includes response.body, "Copy Link"
  end

  # NO PAGE-LEVEL SCRIPT-BALANCE TEST HERE, and that is a decision rather than an
  # omission. Three formulations were tried against a real leak and all three
  # failed, two by accusing innocent code and one by being blind:
  #
  #   refute_includes body, "<%"          — a legitimate JS comment in an existing
  #                                         script reads `// <%= render
  #                                         "studio/modals/host" %> below.` A page
  #                                         is allowed to TALK about ERB.
  #   count("<script") == count("</script>")
  #                                       — 33 vs 32, on ANOTHER legitimate JS
  #                                         comment in shared/_alpine_factories:
  #                                         "(regex literal inside a <script>, not
  #                                         an x-data attribute)". Inside a script
  #                                         element that is text, not a tag.
  #   parser elements == "</script>" count — STRUCTURALLY BLIND. A phantom script
  #                                         opened by leaked prose swallows the
  #                                         next real one and consumes its closer,
  #                                         so both numbers stay equal. Verified
  #                                         against an injected leak: green.
  #
  # The risk this change actually carries is that ITS OWN comments leak, and the
  # test below covers that correctly — on the partials, which contain no
  # JavaScript to confuse a scan. A page-level guard for pre-existing markup is a
  # different job, and shipping one that cannot fail would be worse than none.

  # AND NEITHER OF THE TWO PARTIALS LEAKS ERB, which IS a clean scan because they
  # contain no JavaScript to talk about it. Rendered rather than read, so a
  # comment that lost its terminator shows up as the prose it becomes.
  test "neither partial leaks its own comments into the page" do
    connect_wallet(@user)

    %w[solana_wallet_section referral_section].each do |name|
      html = ApplicationController.renderer.render(
        partial: "accounts/#{name}", locals: { user: @user.reload }
      )

      refute_includes html, "<%", "#{name} leaked an ERB opener into its output"
      refute_includes html, "%>", "#{name} leaked an ERB terminator into its output"
    end
  end

  # THE HEADING BELONGS TO THE CALL SITE, and the two call sites disagree about
  # it on purpose: /account nests the wallet under "Identities" as an h3 beside
  # Google and Email, /profile gives it an h2 of its own from the registry.
  test "the wallet heading comes from each page rather than the partial" do
    partial = Rails.root.join("app/views/accounts/_solana_wallet_section.html.erb").read
    refute_match(/<h[1-6][^>]*>\s*Solana Wallet/, partial.gsub(/<%#.*?%>/m, ""),
      "the partial carries its own heading — /profile would then show it twice")

    connect_wallet(@user)
    sign_in_as(@user)
    get "/account"
    assert_match(%r{<h3[^>]*>\s*Solana Wallet\s*</h3>}, response.body,
      "/account lost the heading the partial gave up")
  end
end
