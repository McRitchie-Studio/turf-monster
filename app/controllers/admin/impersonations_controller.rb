module Admin
  # OPSEC-046: admin "act as user" impersonation. The auth seam lives in
  # ApplicationController (true_user / current_user override / impersonating? /
  # verify_session_token binding to true_user). This controller only flips the
  # session flags + writes the ImpersonationLog audit rows.
  #
  # The admin's REAL session (Studio.session_key + :session_token) is never
  # touched — only the three impersonation keys are added/removed, so returning
  # to the admin account is a clean key-delete with no re-auth.
  class ImpersonationsController < ApplicationController
    # OPSEC-048: FrozenAccountGuard refuses a frozen account every write but this.
    allow_frozen_account_writes only: :destroy, reason: "the admin's Return: ends an impersonation of a frozen account"

    # create is admin-only. destroy is deliberately NOT gated on require_admin:
    # while impersonating, current_user resolves to the (non-admin) target, so
    # require_admin would block an operator from ever returning. It gates on
    # impersonating? instead.
    before_action :require_admin, only: :create

    def create
      target = User.find_by(slug: params[:user_slug])

      # Defense-in-depth — the "Act as" button only renders for eligible users,
      # but a crafted slug must still bounce. Note the impersonating? guard is
      # belt-and-suspenders: a nested attempt already trips require_admin above
      # (current_user is the non-admin target by then), but we keep it explicit.
      if target.nil? || target.admin? || target.id == current_user.id || impersonating?
        return redirect_back fallback_location: admin_users_path,
                             alert: "Can't act as that user."
      end

      rescue_and_log(target: target) do
        # Audit FIRST, then flip the session (OPSEC-046 / Avi HIGH-1). In
        # production a failed write re-raises into handle_unexpected_error, which
        # RENDERS a 302 instead of re-raising — committing the session cookie. If
        # the keys were set before the log, that would leave impersonation active
        # with no enter row. Writing the row first fails closed.
        ImpersonationLog.create!(
          action:      :enter,
          admin:       current_user,
          target_user: target,
          ip:          request.remote_ip,
          user_agent:  request.user_agent
        )

        session[:impersonated_user_id]     = target.id
        session[:true_admin_id]            = current_user.id
        session[:impersonation_started_at] = Time.current.iso8601
      end

      redirect_to account_path, notice: "Now acting as #{target.display_name}."
    end

    def destroy
      # While impersonating, current_user is the target; capture the real admin
      # from the session before we tear it down so the exit row is attributed
      # correctly. account_path is the sensible bounce for a stray DELETE.
      unless impersonating?
        # Clear any stale/expired keys even on a no-op return (Avi NIT-2).
        session.delete(:impersonated_user_id)
        session.delete(:true_admin_id)
        session.delete(:impersonation_started_at)
        return redirect_to account_path
      end

      admin = User.find_by(id: session[:true_admin_id])

      rescue_and_log(target: current_user) do
        ImpersonationLog.create!(
          action:      :exit,
          admin:       admin,
          target_user: current_user,
          ip:          request.remote_ip,
          user_agent:  request.user_agent
        )
      end

      session.delete(:impersonated_user_id)
      session.delete(:true_admin_id)
      session.delete(:impersonation_started_at)

      redirect_to admin_users_path, notice: "Returned to your admin account."
    end
  end
end
