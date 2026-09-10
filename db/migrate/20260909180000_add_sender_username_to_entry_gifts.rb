# The name the invite greets by, FROZEN AT SEND TIME.
#
# The email said "Mr. McRitchie just gave you a free entry" — the sender's
# `name`. The operator wants the USERNAME instead, and specifically the username
# "at the time of course": usernames are changeable (users.username_changed_at
# exists for exactly that), so reading it live would silently rewrite the
# greeting of every invite already sitting in an inbox the moment someone
# renames themselves. A gift is a historical fact about a moment; the name on it
# is part of that fact.
#
# Nullable because every gift already sent has no snapshot to backfill from that
# is trustworthy — the sender may have renamed since. The mailer falls back to
# the live username for those, which is the best available answer for a row that
# predates this column, and exactly the ambiguity the column removes going
# forward.
class AddSenderUsernameToEntryGifts < ActiveRecord::Migration[8.1]
  def change
    add_column :entry_gifts, :sender_username, :string
  end
end
