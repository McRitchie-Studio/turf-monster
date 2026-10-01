# Shared by the agent API tests (test/serializers/api/v1, test/controllers/api/v1).
module AgentApiTestSupport
  AGENT_UA = "python-httpx/0.27.0".freeze

  def mint_api_key(user)
    ApiKey.mint!(user: user, name: "Claude", geo_country: "US", geo_state: "CO", age_result: "not_required")
  end

  def api_get(path, key: @key, params: {})
    headers = { "User-Agent" => AGENT_UA }
    headers["Authorization"] = "Bearer #{key.raw_token}" if key
    get path, params: params, headers: headers
  end

  def json
    JSON.parse(response.body)
  end

  def assert_api_error(status, code)
    assert_response status
    assert_equal %w[error], json.keys
    assert_equal code, json["error"]["code"]
  end

  # A confirmed entry holding the given matchups, built the way the app builds
  # one (so it has a slug), without the payment path.
  def enter!(user, contest, matchups, status: :active, score: 0.0)
    entry = Entry.create!(user: user, contest: contest, status: status, score: score)
    matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
    entry
  end

  def fixture_matchups
    %i[m1 m2 m3 m4 m5 m6].map { |name| slate_matchups(name) }
  end

  # Data queries only: no schema reflection, no transaction bookkeeping.
  def count_queries(&block)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
