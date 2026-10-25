require "test_helper"

# OPSEC-046: admin "act as user" impersonation. The auth seam (true_user /
# current_user override / impersonating? / verify_session_token binding) lives
# in ApplicationController; this exercises the controller flags + audit log +
# the seam's externally observable behaviour.
class Admin::ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)   # role: admin, has email
    @target = users(:jordan) # non-admin web2 (email, no wallet)
    # Fixtures bypass Sluggable's before_save :set_slug, so the slug column is
    # blank. The routes key on :user_slug — backfill the slug the app would
    # generate (name_slug) without firing callbacks.
    [@admin, @target, users(:sam)].each { |u| u.update_column(:slug, u.send(:name_slug)) }
  end

  # --- access control ------------------------------------------------------

  test "non-admin cannot POST impersonate" do
    log_in_as(@target) # non-admin
    assert_no_difference -> { ImpersonationLog.count } do
      post admin_impersonate_path(users(:sam).slug)
    end
    assert_response :redirect
    assert_nil session[:impersonated_user_id]
  end

  # --- enter ---------------------------------------------------------------

  test "admin enters a web2 target: current_user==target, true_user==admin, impersonating? true" do
    log_in_as(@admin)

    assert_difference -> { ImpersonationLog.count }, 1 do
      post admin_impersonate_path(@target.slug)
    end
    assert_redirected_to account_path
    assert_equal @target.id, session[:impersonated_user_id]
    assert_equal @admin.id,  session[:true_admin_id]
    assert session[:impersonation_started_at].present?
    # The admin's REAL session is untouched (this is the whole design).
    assert_equal @admin.id, session[Studio.session_key]

    # The enter row carries admin + target.
    log = ImpersonationLog.recent.first
    assert log.enter?
    assert_equal @admin,  log.admin
    assert_equal @target, log.target_user

    # Externally observable proof of the seam: current_user now resolves to the
    # target (session_state echoes userId), in web2 mode (true_user stays admin,
    # onchain_session? is forced false).
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert_equal @target.id, body["userId"]
    assert_equal "web2",     body["mode"]
  end

  test "cannot impersonate yourself" do
    log_in_as(@admin)
    assert_no_difference -> { ImpersonationLog.count } do
      post admin_impersonate_path(@admin.slug)
    end
    assert_response :redirect
    assert_nil session[:impersonated_user_id]
  end

  test "cannot impersonate another admin" do
    log_in_as(@admin)
    other_admin = users(:sam)
    other_admin.update!(role: "admin")

    assert_no_difference -> { ImpersonationLog.count } do
      post admin_impersonate_path(other_admin.slug)
    end
    assert_response :redirect
    assert_nil session[:impersonated_user_id]
  end

  test "nested impersonation is blocked (the impersonated session can't start a new one)" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_equal @target.id, session[:impersonated_user_id]

    other = users(:sam) # another non-admin
    assert_no_difference -> { ImpersonationLog.count } do
      post admin_impersonate_path(other.slug)
    end
    assert_response :redirect
    # Still acting as the ORIGINAL target — not switched.
    assert_equal @target.id, session[:impersonated_user_id]
  end

  # --- audit-first ordering: enter fails CLOSED (Avi HIGH-1) ---------------

  test "REGRESSION: enter aborts with NO session change when the audit write fails" do
    log_in_as(@admin)

    # The enter row is written BEFORE the three session keys are flipped
    # (audit-first / fail-closed). When the log write blows up, rescue_and_log
    # re-raises and handle_unexpected_error re-raises again in test/dev, so the
    # POST propagates the error rather than activating impersonation with no
    # enter row. (In prod handle_unexpected_error RENDERS a 302, but the keys
    # are still never set — the raise happens before they're assigned.)
    ImpersonationLog.stub(:create!, ->(*_a, **_k) { raise StandardError, "audit write failed" }) do
      err = assert_raises(StandardError) do
        post admin_impersonate_path(@target.slug)
      end
      assert_equal "audit write failed", err.message
    end

    # A fresh authed request still resolves to the real admin — impersonation
    # never activated, and none of the three impersonation keys were written.
    get session_state_account_path, as: :json
    assert_response :success
    assert_equal @admin.id, JSON.parse(response.body)["userId"]
    assert_nil session[:impersonated_user_id]
    assert_nil session[:true_admin_id]
    assert_nil session[:impersonation_started_at]
  end

  # --- the verify_session_token regression --------------------------------

  test "REGRESSION: a normal authenticated request while impersonating does NOT force-logout" do
    # If verify_session_token bound to current_user (the target) instead of
    # true_user (the admin whose token is in the cookie), the target's differing
    # session_token would mismatch every request and force a logout → redirect
    # to signin. This is the exact bug the seam's true_user binding fixes.
    refute_equal @admin.session_token, @target.session_token,
                 "precondition: tokens differ, so a wrong binding would force-logout"

    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_equal @target.id, session[:impersonated_user_id]

    get account_path # a normal, auth-required, full-page request
    assert_response :success # NOT a 302 to signin

    # Still impersonating afterwards (session not cleared by a force-logout).
    assert_equal @target.id, session[:impersonated_user_id]
    get session_state_account_path, as: :json
    assert_equal @target.id, JSON.parse(response.body)["userId"]
  end

  # --- onchain flag isolation ---------------------------------------------

  test "onchain_session? is false while impersonating even if session[:onchain] was true" do
    log_in_as_onchain(@admin) # admin authenticates via Phantom → session[:onchain] = true
    assert session[:onchain], "precondition: admin has a live web3 session"

    post admin_impersonate_path(@target.slug) # @target is web2
    assert_equal @target.id, session[:impersonated_user_id]
    assert session[:onchain], "the raw flag is left in the session, untouched"

    # ...but the impersonated view must read as web2 (server-sign), never web3,
    # so the admin's wallet privilege can't leak into the target's session.
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert_equal @target.id, body["userId"]
    assert_equal "web2", body["mode"], "impersonated session must not be web3"
  end

  test "web3 (phantom-only) target cannot transact an on-chain entry while impersonated" do
    web3_target = users(:sam) # non-admin, has a Phantom wallet
    contest = contests(:one)
    contest.entries.create!(user: web3_target, status: :cart)

    log_in_as(@admin)
    post admin_impersonate_path(web3_target.slug)
    assert_equal web3_target.id, session[:impersonated_user_id]

    # onchain_session? is false while impersonating, so the entry flow's
    # "Phantom session required" gate fires — the admin can't borrow the
    # target's wallet signature.
    assert_no_difference -> { PendingTransaction.count } do
      post prepare_entry_contest_path(contest), as: :json
    end
    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  # --- exit ----------------------------------------------------------------

  test "exit restores the admin even though current_user is the non-admin target" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_equal @target.id, session[:impersonated_user_id]

    # destroy is deliberately NOT require_admin — current_user is the non-admin
    # target here, so an admin gate would trap the operator. It must still work.
    assert_difference -> { ImpersonationLog.where(action: :exit).count }, 1 do
      delete admin_stop_impersonating_path
    end
    assert_redirected_to admin_users_path
    assert_nil session[:impersonated_user_id]
    assert_nil session[:true_admin_id]
    assert_nil session[:impersonation_started_at]
    # Admin's real session survived the whole round trip.
    assert_equal @admin.id, session[Studio.session_key]

    log = ImpersonationLog.where(action: :exit).recent.first
    assert_equal @admin,  log.admin
    assert_equal @target, log.target_user

    # Back to the admin.
    get session_state_account_path, as: :json
    assert_equal @admin.id, JSON.parse(response.body)["userId"]
  end

  test "destroy is a no-op redirect when not impersonating" do
    log_in_as(@admin)
    assert_no_difference -> { ImpersonationLog.count } do
      delete admin_stop_impersonating_path
    end
    assert_response :redirect
  end

  # --- logout while impersonating -----------------------------------------

  test "logout while impersonating logs the exit (reason: logout) and clears the 3 keys" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_equal @target.id, session[:impersonated_user_id]

    assert_difference -> { ImpersonationLog.where(action: :exit).count }, 1 do
      get logout_path # engine draws logout as a GET → SessionsController#destroy
    end

    # Impersonation keys gone...
    assert_nil session[:impersonated_user_id]
    assert_nil session[:true_admin_id]
    assert_nil session[:impersonation_started_at]
    # ...and the admin's real session is wiped too (full logout).
    assert_nil session[Studio.session_key]

    log = ImpersonationLog.where(action: :exit).recent.first
    assert_equal "logout", log.reason
    assert_equal @admin,   log.admin
    assert_equal @target,  log.target_user
  end

  # --- defense-in-depth guards (fund-drain + key-export) -------------------

  test "withdraw is blocked while impersonating" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_no_difference -> { TransactionLog.count } do
      post withdraw_wallet_path, params: { amount: "10", destination_info: "wherever" }
    end
    assert_redirected_to account_path
  end

  test "wallet export is blocked while impersonating" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    # The guard redirects; the un-guarded path renders JSON, never a redirect —
    # and export_initiated_at is never stamped.
    assert_no_changes -> { @target.reload.export_initiated_at } do
      post initiate_wallet_export_account_path
    end
    assert_redirected_to account_path
  end

  # --- identity-mutation lockout while impersonating (Avi HIGH-2) ----------

  test "identity mutations are blocked while impersonating (no first-email takeover)" do
    log_in_as(@admin)
    post admin_impersonate_path(@target.slug)
    assert_equal @target.id, session[:impersonated_user_id]

    # The set-first-email → magic-link → durable-takeover vector: while acting
    # as the target the admin tries to repoint the account at an address they
    # control, via the real account route (PATCH /account → accounts#update).
    # block_account_mutation_while_impersonating must refuse it.
    assert_no_changes -> { @target.reload.email } do
      patch account_path, params: { user: { email: "attacker@evil.example" } }
    end
    assert_redirected_to account_path
    # Prove the GUARD bounced it (its alert) — not the OOB email-confirm branch,
    # which also redirects to account_path but sets NO alert and would enqueue a
    # confirmation email. The matching alert is unambiguous proof the body never ran.
    assert_equal "Account changes are disabled while acting as another user.", flash[:alert]

    # The auth-binding surface is closed the same way: link_solana (JSON) → 403.
    post link_solana_account_path, as: :json
    assert_response :forbidden
    assert_equal "Account changes are disabled while acting as another user.",
                 JSON.parse(response.body)["error"]
  end

  # --- "Act as" button on the admin users index ---------------------------

  test "admin users index shows Act as for non-admins but not for admins" do
    log_in_as(@admin)
    get admin_users_path
    assert_response :success
    # A POST button targeting the non-admin target's impersonate route…
    assert_match admin_impersonate_path(@target.slug), response.body
    # …and none targeting the admin themselves.
    assert_no_match admin_impersonate_path(@admin.slug), response.body
  end

  # --- banner --------------------------------------------------------------

  test "impersonation banner renders only while impersonating" do
    log_in_as(@admin)

    get account_path
    assert_response :success
    # studio-engine's studio/banners/_impersonation since
    # /tasks/turf-readopts-engine-navbar (Studio.navbar_header_bars), which says
    # "Logged in as" where Turf's own bar said "Acting as".
    assert_no_match(/Logged in as/, response.body)

    post admin_impersonate_path(@target.slug)
    get account_path
    assert_response :success
    assert_match(/Logged in as <strong>#{Regexp.escape(@target.display_name)}<\/strong>/, response.body)
    # The SSR return button is present and points at the real admin.
    assert_match("Return to #{@admin.display_name}", response.body)
  end
end
