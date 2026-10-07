require "test_helper"

# [integration] The operator's freeze and unfreeze (OPSEC-048), behind the
# admin wall: each needs a reason and leaves an AccountFreezeEvent naming the
# admin; a non-admin can do neither; an admin account cannot be frozen.
class Admin::AccountFreezesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Fixtures skip Sluggable; the routes key users by slug.
    User.where(slug: nil).find_each { |u| u.update_column(:slug, "fixture-#{u.id}") }
    @admin  = users(:alex)
    @player = users(:jordan)
  end

  test "an admin freezes a player with a reason, and the audit row names them both" do
    log_in_as(@admin)

    assert_difference -> { AccountFreezeEvent.count }, 1 do
      post admin_freeze_user_path(@player.slug), params: { reason: "chargeback on order 12" }
    end

    assert_redirected_to admin_users_path
    assert @player.reload.frozen?
    assert_equal "chargeback on order 12", @player.frozen_reason
    event = AccountFreezeEvent.recent.first
    assert_equal ["freeze", "admin", @admin, @player], [event.action, event.source, event.admin, event.user]
  end

  test "an admin unfreezes a player with a reason, and that is audited too" do
    @player.freeze!(reason: "dispute")
    log_in_as(@admin)

    assert_difference -> { AccountFreezeEvent.count }, 1 do
      delete admin_unfreeze_user_path(@player.slug), params: { reason: "dispute won" }
    end

    assert_not @player.reload.frozen?
    event = AccountFreezeEvent.recent.first
    assert_equal ["unfreeze", "dispute won", @admin], [event.action, event.reason, event.admin]
  end

  test "no reason, no freeze" do
    log_in_as(@admin)

    assert_no_difference -> { AccountFreezeEvent.count } do
      post admin_freeze_user_path(@player.slug), params: { reason: "  " }
    end
    assert_not @player.reload.frozen?
    assert_equal "Give a reason.", flash[:alert]
  end

  test "an admin account cannot be frozen" do
    other_admin = User.create!(name: "Mod", username: "modfreeze", email: "modfreeze@mcritchie.studio", role: "admin")
    log_in_as(@admin)

    post admin_freeze_user_path(other_admin.slug), params: { reason: "test" }
    assert_not other_admin.reload.frozen?
  end

  test "a player cannot freeze or unfreeze anyone" do
    @player.freeze!(reason: "dispute")
    sam = users(:sam)
    log_in_as(sam)

    assert_no_difference -> { AccountFreezeEvent.count } do
      post admin_freeze_user_path(users(:casey).slug), params: { reason: "griefing" }
      delete admin_unfreeze_user_path(@player.slug), params: { reason: "friend" }
    end
    assert_not users(:casey).reload.frozen?
    assert @player.reload.frozen?
  end

  test "the users page offers freeze to a player in good standing and unfreeze with the reason to a frozen one" do
    @player.freeze!(reason: "chargeback on order 12")
    log_in_as(@admin)

    get admin_users_path
    assert_response :success
    assert_select "form[action=?]", admin_unfreeze_user_path(@player.slug)
    assert_select "[data-freeze-state=frozen]", text: /chargeback on order 12/
    assert_select "form[action=?]", admin_freeze_user_path(users(:sam).slug)
  end
end
