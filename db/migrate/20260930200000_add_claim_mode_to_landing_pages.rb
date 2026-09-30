# Claim mode: a landing page whose CTA collects the SIGNUP (email magic link or
# Google) and promises a free entry the operator hand-mints later, instead of
# sending the visitor into the contest to pay. Off by default, so every existing
# page keeps its contest CTA until an operator ticks the box.
class AddClaimModeToLandingPages < ActiveRecord::Migration[8.1]
  def change
    add_column :landing_pages, :claim_mode, :boolean, default: false, null: false
  end
end
