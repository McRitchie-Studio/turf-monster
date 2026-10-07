module Admin
  # OPSEC-048: the operator's hand on the account freeze, now that the payment
  # webhooks that used to set it are parked (FiatRailsParked). Freeze and
  # unfreeze each take a reason and leave an AccountFreezeEvent naming the
  # admin; User#freeze! and User#unfreeze! write both, in one transaction.
  #
  #   POST   /admin/users/:user_slug/freeze   reason=…   freeze
  #   DELETE /admin/users/:user_slug/freeze   reason=…   unfreeze
  #
  # Each write runs inside rescue_and_log, so a failed freeze or unfreeze leaves
  # an ErrorLog row targeting the player. rescue_and_log re-raises by contract;
  # the action catches that and answers the operator with an alert, not a 500.
  #
  # Admin accounts cannot be frozen: a frozen admin is refused every write,
  # this unfreeze included, so the hold could lock out the operator who has to
  # lift it.
  class AccountFreezesController < ApplicationController
    before_action :require_admin
    before_action :set_user
    before_action :require_reason

    def create
      return redirect_back_or_to(admin_users_path, alert: "Admin accounts cannot be frozen.") if @user.admin?

      froze = rescue_and_log(target: @user) { @user.freeze!(reason: @reason, by: current_user, source: "admin") }
      if froze
        redirect_back_or_to admin_users_path, notice: "#{@user.display_name} is frozen."
      else
        redirect_back_or_to admin_users_path, alert: "#{@user.display_name} is already frozen."
      end
    rescue StandardError
      redirect_back_or_to admin_users_path, alert: "Could not freeze #{@user.display_name}."
    end

    def destroy
      thawed = rescue_and_log(target: @user) { @user.unfreeze!(reason: @reason, by: current_user, source: "admin") }
      if thawed
        redirect_back_or_to admin_users_path, notice: "#{@user.display_name} is unfrozen."
      else
        redirect_back_or_to admin_users_path, alert: "#{@user.display_name} is not frozen."
      end
    rescue StandardError
      redirect_back_or_to admin_users_path, alert: "Could not unfreeze #{@user.display_name}."
    end

    private

    def set_user
      @user = User.find_by(slug: params[:user_slug])
      redirect_back_or_to(admin_users_path, alert: "No such user.") unless @user
    end

    def require_reason
      @reason = params[:reason].to_s.strip
      redirect_back_or_to(admin_users_path, alert: "Give a reason.") if @reason.empty?
    end
  end
end
