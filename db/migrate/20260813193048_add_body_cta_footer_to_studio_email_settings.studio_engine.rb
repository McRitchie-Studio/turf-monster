# This migration comes from studio_engine (originally 20260813010000)
# The email BELOW the banner: its body copy, its call to action, and the footer
# every email shares.
#
# Same rule as the banner's words — nil means INHERIT the registry default, so
# an app that never opens /admin/emails sends exactly what it sent before.
#
# The FOOTER is app-wide rather than per-email, and it lives in this same table
# under a reserved key (Studio::EmailSetting::FOOTER_KEY). A separate table for
# two strings would cost a migration, a model and a join to say the same thing;
# a reserved key keeps one place to look for "what has the operator changed".
class AddBodyCtaFooterToStudioEmailSettings < ActiveRecord::Migration[7.2]
  def change
    change_table :studio_email_settings, bulk: true do |t|
      # The paragraph(s) under the header. Rendered through
      # simple_format(sanitize: true), which makes blank lines into paragraphs and
      # strips scripts and event handlers — inline tags like a and strong survive.
      # The author is an admin, so that line is deliberate rather than an oversight.
      t.text    :body

      t.string  :cta_text
      # Hex, defaulting to the app's primary. Stored rather than derived so an
      # operator can make one email's button stand out.
      t.string  :cta_color
      # NULL, not false: three states again. nil inherits the registry's answer,
      # true and false are the operator's.
      t.boolean :cta_enabled

      # Footer, on the reserved row.
      t.string  :discord_url
    end
  end
end
