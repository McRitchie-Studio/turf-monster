module UserMergeable
  extend ActiveSupport::Concern

  private

  def merge_users!(survivor:, absorbed:)
    # Always keep the lower id
    if survivor.id > absorbed.id
      survivor, absorbed = absorbed, survivor
    end

    ActiveRecord::Base.transaction do
      # Transfer entries
      Entry.where(user_id: absorbed.id).update_all(user_id: survivor.id)

      # Fill in blank auth fields on survivor
      survivor.email = absorbed.email if survivor.email.blank? && absorbed.email.present?
      survivor.name = absorbed.name if survivor.name.blank? && absorbed.name.present?
      if survivor.provider.blank? && absorbed.provider.present?
        survivor.provider = absorbed.provider
        survivor.uid = absorbed.uid
      end

      # Update ErrorLog polymorphic references
      ErrorLog.where(target_type: "User", target_id: absorbed.id).update_all(target_id: survivor.id)
      ErrorLog.where(parent_type: "User", parent_id: absorbed.id).update_all(parent_id: survivor.id)

      survivor.save!
      absorbed.destroy!
    end

    set_app_session(survivor)
    survivor
  end
end
