# frozen_string_literal: true

# COMING SOON — the third state the contests page reads about an open contest.
#
# It is a FLAG, not a status. `status` is pending/open/settled and it is what
# the on-chain lifecycle and the entry path read; this column changes NOTHING
# about either. It says only "advertise this one, but tell readers it is not
# ready yet" — the featured rail sorts it below the plain-open contests, dims
# its card and sashes it "Coming Soon". Entry is deliberately NOT blocked: a
# reader who clicks through gets the ordinary contest page.
#
# Defaulting false with NOT NULL means every existing contest keeps exactly the
# behaviour it has today, and the view never has to branch on nil.
class AddComingSoonToContests < ActiveRecord::Migration[8.1]
  def change
    add_column :contests, :coming_soon, :boolean, default: false, null: false
  end
end
