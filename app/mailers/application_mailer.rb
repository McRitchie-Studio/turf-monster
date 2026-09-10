class ApplicationMailer < ActionMailer::Base
  TRANSACTIONAL_FROM = "Turf Monster <team@turfmonster.media>"
  MARKETING_FROM = "Alex from Turf Monster <alex@turfmonster.media>"
  RESEND_FROM = "McRitchie Studio <team@mcritchie.studio>"

  default from: -> { Studio.mailer_from || Studio.mailer_from_for_transport(ses_from: TRANSACTIONAL_FROM, resend_from: RESEND_FROM) }
  layout "mailer"

  private

  def marketing_from
    Studio.marketing_from_for_transport(ses_from: MARKETING_FROM, resend_from: RESEND_FROM)
  end
end
