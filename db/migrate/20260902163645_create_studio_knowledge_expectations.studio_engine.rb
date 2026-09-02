# This migration comes from studio_engine (originally 20260902000001)
# Reference migration for Studio::KnowledgeExpectation — the "what SHOULD
# exist" half of the knowledge layer's coverage view. Installed per consumer
# like the other studio_* tables (`bin/rails studio_engine:install:migrations
# && bin/rails db:migrate`); do not hand-copy.
#
# STYLE NOTE: reference migrations are written omakase-rubocop-compatible
# (spaces inside array brackets) because the installed copy is linted by the
# CONSUMER's rubocop, not this gem's.
class CreateStudioKnowledgeExpectations < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_knowledge_expectations do |t|
      # Which business expects the document (same vocabulary as knowledge docs).
      t.string :entity, null: false
      t.string :title, null: false
      # Folder the fulfilling documents live under; display + default, not a matcher.
      t.string :path, null: false, default: ""
      t.string :category
      # once: a single document satisfies it forever.
      # monthly: one document per calendar month from start_on onward.
      t.string :cadence, null: false, default: "once"
      # First month a monthly expectation owes a document (defaults to creation month).
      t.date :start_on
      # Provenance: "diligence tracker item 14", "lender checklist", …
      t.string :source_note
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :studio_knowledge_expectations, [ :entity, :active ]
  end
end
