# Previews at /rails/mailers/drop_signup_mailer — the four drop emails Alex
# approves before any real send. Each is built on an UNSAVED DropSignup, so a
# preview mints no magic link and writes nothing.
class DropSignupMailerPreview < ActionMailer::Preview
  def confirmation_new_player
    DropSignupMailer.confirmation(new_signup, variant: :new_player)
  end

  def confirmation_existing_player
    DropSignupMailer.confirmation(existing_signup, variant: :existing_player)
  end

  def announcement_new_player
    DropSignupMailer.announcement(new_signup, variant: :new_player)
  end

  def announcement_existing_player
    DropSignupMailer.announcement(existing_signup, variant: :existing_player)
  end

  private

  def new_signup
    DropSignup.new(email: "new-player@example.com", slate_key: NextSlateDrop::SLATE_KEY, source: "tiktok")
  end

  def existing_signup
    user = User.where.not(email: nil).first || User.new(email: "player@example.com", username: "turf-fan")
    DropSignup.new(email: user.email, user: user, slate_key: NextSlateDrop::SLATE_KEY)
  end
end
