# This migration comes from studio_engine (originally 20260902000002)
# Links a knowledge doc to the expectation it fulfills — set at triage, an
# EXPLICIT pointer rather than name-matching (a fuzzy match silently merges
# lookalikes; an id never does). Installed per consumer; do not hand-copy.
class AddExpectationToStudioKnowledgeDocs < ActiveRecord::Migration[7.2]
  def change
    add_column :studio_knowledge_docs, :expectation_id, :bigint
    add_index :studio_knowledge_docs, :expectation_id
  end
end
