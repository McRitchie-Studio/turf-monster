# This migration comes from studio_engine (originally 20261005120000)
# One respondent's answers to one survey (Studio::SurveyResponse,
# docs/SURVEYS.md). Surveys themselves are defined in app code, not stored; the
# row keys on the survey's slug and stamps the definition version it was taken
# under.
#
# `answers` is { question_key => { "value", "label", "type", "display",
# "answered_at" } }: each answer carries the question label and option label it
# was given under, so a later edit to the definition never rewrites history.
#
# No raw IP and no raw user agent: user_agent_class is mobile / tablet /
# desktop / bot / unknown, which is all the results panel reads.
#
# The two partial unique indexes enforce ONE IN-PROGRESS response per signed-in
# user, and per anonymous session token, for each survey. Completed rows fall
# out of both, so a respondent's history is unconstrained.
class CreateStudioSurveyResponses < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_survey_responses do |t|
      t.string :survey_slug, null: false
      t.string :survey_version
      if connection.adapter_name.match?(/postg/i)
        t.jsonb :answers, null: false, default: {}
      else
        t.json :answers, null: false, default: {}
      end
      t.bigint :user_id
      t.string :email_ref
      t.string :session_token
      t.string :user_agent_class
      t.string :current_key
      t.datetime :started_at, null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :studio_survey_responses, %i[survey_slug completed_at]
    add_index :studio_survey_responses, :user_id
    add_index :studio_survey_responses, :email_ref
    add_index :studio_survey_responses, %i[survey_slug user_id], unique: true,
              where: "completed_at IS NULL AND user_id IS NOT NULL",
              name: "index_studio_survey_responses_one_open_per_user"
    add_index :studio_survey_responses, %i[survey_slug session_token], unique: true,
              where: "completed_at IS NULL AND session_token IS NOT NULL",
              name: "index_studio_survey_responses_one_open_per_session"
  end
end
