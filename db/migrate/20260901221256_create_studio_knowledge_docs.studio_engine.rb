# This migration comes from studio_engine (originally 20260901000001)
# Reference migration for the Studio::KnowledgeDoc model. Like studio_links,
# each consumer app installs its own copy into db/migrate
# (`bin/rails studio_engine:install:migrations && bin/rails db:migrate`) so the
# table is created in the app's database. Do not hand-copy — a hand copy
# collides with the installed copy on `class CreateStudioKnowledgeDocs`.
class CreateStudioKnowledgeDocs < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_knowledge_docs do |t|
      t.string :title, null: false
      # Which business the document belongs to (e.g. "commercial-welding-llc").
      # One app can host several entities' knowledge; every read is entity-scoped.
      t.string :entity, null: false
      # Folder path with no leading/trailing slash ("financials/aging-inventory/2026-08").
      # Folders are implicit — they exist because a document claims the path —
      # and the S3 key mirrors it, so the bucket stays human-browsable.
      t.string :path, null: false, default: ""
      t.string :category
      t.string :mime_type
      # The document's own as-of date (an August aging report dated August),
      # distinct from created_at (when it was uploaded).
      t.date :document_date
      # inbox -> filed -> superseded. Uploads land as inbox for agent triage.
      t.string :status, null: false, default: "inbox"
      # Per-agent access map: {"samson" => "full", "dawn" => "aware"}.
      # "aware" = the agent knows the document exists and gets the safe summary,
      # not the contents; absent agents default to "none".
      t.jsonb :access, null: false, default: {}
      t.jsonb :tags, null: false, default: []
      # The safe summary — what an "aware" agent may read and repeat.
      t.text :summary
      # Provenance: who/where the document came from ("broker email 2026-08-30").
      t.string :source_note
      t.string :uploaded_by
      # Object storage pointer (Studio::S3 logical key); nil for a metadata-only
      # record. byte_size is captured at attach time for the index view.
      t.string :s3_key
      t.bigint :byte_size
      # Set on the OLD row when a newer document replaces it.
      t.bigint :superseded_by_id

      t.timestamps
    end

    add_index :studio_knowledge_docs, [:entity, :status]
    add_index :studio_knowledge_docs, [:entity, :path]
    add_index :studio_knowledge_docs, :s3_key, unique: true
    add_index :studio_knowledge_docs, :superseded_by_id
  end
end
