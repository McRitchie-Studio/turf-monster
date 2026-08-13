# This migration comes from studio_engine (originally 20260812210000)
# The banner's WORDS, editable by the operator alongside its tint.
#
# Separate migration rather than an edit to CreateStudioEmailSettings: that one
# has already been installed and run in a host, and rewriting an applied
# migration is how a schema quietly diverges from the file that claims to
# describe it.
#
# Every column is nullable, and nil means INHERIT — the registry default applies.
# That distinction is the whole design: "the operator has not set this" and "the
# operator set this to empty" are different answers, and a NOT NULL default
# would collapse them.
class AddCopyToStudioEmailSettings < ActiveRecord::Migration[7.2]
  def change
    change_table :studio_email_settings, bulk: true do |t|
      # Supports a {name} placeholder, which is what keeps the field honest for
      # an email whose greeting is per-recipient.
      t.string  :header

      # Used when no name is known. A magic link may be the first contact we
      # ever have with someone, so "Welcome {name}!" has to have somewhere to
      # fall back to that is not "Welcome !".
      t.string  :header_fallback

      t.string  :subtext

      # Blank inherits the registry logo. hide_logo is the deliberate "no logo"
      # answer — without it, blank would have to mean both inherit and none.
      t.string  :logo_url
      t.boolean :hide_logo, null: false, default: false
    end
  end
end
