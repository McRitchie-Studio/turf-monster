require "test_helper"

# [unit] turf-frozen-account-followups: a frozen account that is also a parked
# identity (User::PARKED_IDENTITIES) and has drifted off its parked username
# must still sign in. Every sign-in path calls #claim_parked_identity!, which
# used to try to rename the account back, hit the freeze's identity guard
# (frozen_identity_change?) and raise ActiveRecord::RecordInvalid, so the
# frozen house account could not sign in at all. A freeze holds the username
# where it is: the claim skips the rename and leaves the rest of the identity
# (role, name, email) to reconcile as before.
class FrozenParkedIdentityTest < ActiveSupport::TestCase
  PARKED_EMAIL = "mack@mcritchie.studio".freeze

  setup do
    @parked = User.parked_identity_for(email: PARKED_EMAIL)
    @user = User.create!(email: PARKED_EMAIL, email_verified_at: Time.current, name: "Mack McRitchie",
                         username: "mack-drifted-#{SecureRandom.hex(2)}")
    # create claims the parked username when it is free; drift it off on purpose.
    @user.update_column(:username, "mack-drifted-#{SecureRandom.hex(2)}")
    @drifted = @user.reload.username
  end

  test "a frozen parked identity with a drifted username claims without raising and keeps its username" do
    @user.freeze!(reason: "test", source: "console")

    assert_nothing_raised { @user.claim_parked_identity! }
    assert_equal @drifted, @user.reload.username, "a freeze holds the username where it is"
    assert @user.frozen?
  end

  test "a frozen parked identity still reconciles its role" do
    @user.update_column(:role, "admin")
    @user.freeze!(reason: "test", source: "console")

    assert_nothing_raised { @user.claim_parked_identity! }
    assert_equal @parked[:role], @user.reload.role
    assert_equal @drifted, @user.username
  end

  test "control: the same account in good standing is renamed back to its parked username" do
    assert @user.claim_parked_identity!
    assert_equal @parked[:username], @user.reload.username
  end
end
