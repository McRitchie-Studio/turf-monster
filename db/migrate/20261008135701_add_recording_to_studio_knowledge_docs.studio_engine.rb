# This migration comes from studio_engine (originally 20261008120000)
# A meeting's recording, stored beside its transcript. The document row stays
# the transcript (s3_key); these four columns point at ONE recording object in
# the same private bucket, written by Studio::KnowledgeDoc#attach_recording!.
#
# recording_source_url is the external page the recording came from (the
# notetaker's share page), kept as a link. It is never fetched.
#
# Installed per consumer; do not hand-copy. An app that has not installed this
# yet keeps working: Studio::KnowledgeDoc#recording? answers false without the
# columns.
class AddRecordingToStudioKnowledgeDocs < ActiveRecord::Migration[7.2]
  def change
    add_column :studio_knowledge_docs, :recording_key, :string
    add_column :studio_knowledge_docs, :recording_mime_type, :string
    add_column :studio_knowledge_docs, :recording_byte_size, :bigint
    add_column :studio_knowledge_docs, :recording_source_url, :text
    add_index :studio_knowledge_docs, :recording_key, unique: true
  end
end
