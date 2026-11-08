# The account-primitive rules every Studio app shares, kept out of user.rb so
# that file's line numbers (cited by docs/workflows) do not move.
#
# ROLE: one list, held in the database too (CHECK users_role_known). Turf once
# seeded a third spelling, "user"; it meant viewer, and the rows moved there.
#
# BIRTHDAY: stored split, birth_month + birth_day apart from birth_year, so a
# partial birthday ("Oct 1, year unknown") is valid data. Alex McRitchie's
# ruling; see the database audit under .agents/epics/audits. CHECK
# users_birthday_valid holds the shape (month 1-12, a day only with a month and
# within it, year >= 1900); this concern holds the two rules a CHECK cannot: no
# future year, and Feb 29 only in a leap year when the year is known. The old
# whole-date columns are ignored and dropped in a later release.
#
# EMAIL LOOKUP: a Google callback may carry no email. find_by(email: nil)
# matches ANY account without one (wallet sign-ups), so the lookup runs only
# for a real address.
module User::AccountRules
  extend ActiveSupport::Concern

  ROLES = %w[viewer admin].freeze

  included do
    self.ignored_columns += %w[date_of_birth birth_date]

    validates :role, inclusion: { in: ROLES }
    validate :birthday_is_real, if: -> { birth_year_changed? || birth_month_changed? || birth_day_changed? }
  end

  class_methods do
    def account_for_google_email(auth)
      email = auth.info.email.to_s.strip.downcase.presence
      email && where("LOWER(email) = ?", email).first
    end
  end

  # The whole date only when all three parts are known, else nil. An age check
  # needs the whole date; a partial birthday never passes one.
  def birthday_date
    return nil unless birth_year && birth_month && birth_day

    Date.new(birth_year, birth_month, birth_day)
  rescue Date::Error
    nil
  end

  def birthday_date=(date)
    self.birth_year = date&.year
    self.birth_month = date&.month
    self.birth_day = date&.day
  end

  private

  def birthday_is_real
    errors.add(:birth_year, "cannot be in the future") if birth_year && birth_year > Date.current.year
    errors.add(:birth_year, "must be 1900 or later") if birth_year && birth_year < 1900
    errors.add(:birth_month, "must be 1 to 12") if birth_month && !birth_month.between?(1, 12)
    errors.add(:birth_day, "needs a month") if birth_day && birth_month.nil?
    return unless birth_day && birth_month&.between?(1, 12)

    leap_or_unknown = birth_year.nil? || Date.leap?(birth_year)
    errors.add(:birth_day, "is not a day in that month") unless Date.valid_date?(leap_or_unknown ? 2000 : 2001, birth_month, birth_day)
  end
end
