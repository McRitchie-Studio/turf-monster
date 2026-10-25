require "test_helper"

# [unit] UsernameModalHelper — which username card a player meets.
#
# modals/_username decided this in ERB branches until studio-engine 0.114.0 gave
# blocks/_change_username a `locked:` local (turf-readopts-engine-modals). The
# decision is product policy and stays in this app; the engine only draws it. A
# wrong branch here renders a finished-looking card that offers a rename the
# server will refuse, or refuses one it would allow, so each branch is pinned.
class UsernameModalHelperTest < ActionView::TestCase
  include UsernameModalHelper
  include ApplicationHelper

  Player = Struct.new(:username, :can_change_username, :phantom, keyword_init: true) do
    def can_change_username? = can_change_username
    def phantom_wallet? = phantom
  end

  attr_accessor :current_user, :frozen

  def account_frozen? = !!frozen

  setup do
    self.frozen = false
    self.current_user = Player.new(username: "turfking", can_change_username: true, phantom: false)
  end

  test "an open rename hands the engine this app's on-chain callbacks and no lock" do
    locals = username_modal_locals

    assert_nil locals[:locked]
    assert_equal "turfking", locals[:current_username]
    assert_equal update_username_account_path, locals[:submit_url]
    assert_equal confirm_username_account_path, locals[:finalize_url]
    assert_equal "tmUsernameFinalize", locals[:finalize_hook]
    assert_equal "studio:username-saved", locals[:saved_event]
    assert_equal false, locals[:leveling], "TM's quest-success beat owns the celebration"
    assert_includes locals[:description], "managed wallet"
  end

  test "a self-custodied wallet is told the wallet opens, naming no wallet brand" do
    current_user.phantom = true

    assert_includes username_modal_locals[:description], "Saving opens your wallet to sign."
    assert_not_includes username_modal_locals[:description], "Phantom"
  end

  test "a frozen account gets the locked card with its reason and no rename locals" do
    self.frozen = true
    locals = username_modal_locals

    assert_equal "Username locked", locals.dig(:locked, :title)
    assert_includes locals.dig(:locked, :subtitle), FrozenAccount::CTA_REASON
    assert_nil locals.dig(:locked, :cta_href), "a frozen account has nowhere to go but Dismiss"
    assert_nil locals[:submit_url]
  end

  test "frozen wins over a rename that would otherwise be open" do
    self.frozen = true
    current_user.can_change_username = true

    assert_equal "Username locked", username_modal_locals.dig(:locked, :title)
  end

  test "no contest entered yet locks the card and points at the main contest" do
    current_user.can_change_username = false
    contest = Contest.where(status: :open).order(created_at: :desc).first
    assert contest, "fixtures must carry an open contest for this to mean anything"
    SeasonConfig.set_main_contest!(contest)

    locked = username_modal_locals[:locked]
    assert_equal "Enter Contest First", locked[:title]
    assert_equal "Enter #{contest.name}", locked[:cta_label]
    assert_equal contest_path(contest), locked[:cta_href]
  end

  test "with nothing open the locked card points at the contest index" do
    current_user.can_change_username = false
    Contest.update_all(status: Contest.statuses[:settled])

    locked = username_modal_locals[:locked]
    assert_equal "Browse Contests", locked[:cta_label]
    assert_equal contests_path, locked[:cta_href]
  end
end
