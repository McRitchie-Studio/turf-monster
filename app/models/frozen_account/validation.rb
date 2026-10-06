module FrozenAccount
  # The freeze where a write LANDS, so a path that never passes a controller (a
  # job, a console, a surface not built yet) still cannot write for a frozen
  # account. The controllers refuse first and answer properly; this is the floor.
  #
  #   include FrozenAccount::Validation
  #   validates_account_not_frozen :user, on: :create
  #   validates_account_not_frozen -> { entry&.user }, on: :create
  #
  # `owner` is a method name or a lambda run on the record. Any other option
  # (on:, if:, unless:) passes straight to `validate`.
  module Validation
    extend ActiveSupport::Concern

    class_methods do
      def validates_account_not_frozen(owner, **options)
        validate(**options) do
          account = owner.respond_to?(:call) ? instance_exec(&owner) : public_send(owner)
          errors.add(:base, :account_frozen, message: FrozenAccount::MESSAGE) if account.is_a?(User) && account.frozen?
        end
      end
    end
  end
end
