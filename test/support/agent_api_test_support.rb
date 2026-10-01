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

  def api_write(verb, path, body: {}, key: @key, headers: {})
    headers = { "User-Agent" => AGENT_UA }.merge(headers)
    headers["Authorization"] = "Bearer #{key.raw_token}" if key
    send(verb, path, params: body, headers: headers, as: :json)
  end

  # POST /api/v1/contests/:slug/entries. `idem: nil` sends no Idempotency-Key.
  def api_enter(contest, matchup_ids, idem: SecureRandom.uuid, key: @key, **body)
    headers = idem ? { "Idempotency-Key" => idem } : {}
    api_write(:post, api_v1_contest_entries_path(contest.slug), key: key, headers: headers,
              body: { matchup_ids: matchup_ids }.merge(body))
  end

  def json
    JSON.parse(response.body)
  end

  # A player whose wallet the server alone holds: the one the API may sign for.
  def make_managed!(user)
    user.update!(web3_solana_address: nil,
                 web2_solana_address: "Managed#{SecureRandom.hex(6)}",
                 encrypted_web2_solana_private_key: "ciphertext")
    user
  end

  # A paid contest with an on-chain Contest PDA, in a configured season.
  def make_onchain!(contest)
    contest.update!(onchain_contest_id: "onchain-#{SecureRandom.hex(3)}", season_id: 1)
    SeasonConfig.set_current!(1)
    contest
  end

  # Two more pickable teams on the fixture slate, so a second lineup exists.
  def extra_matchups(slate = slates(:one))
    %w[g h].map do |letter|
      team = Team.create!(name: "Team #{letter.upcase}", short_name: "TM#{letter.upcase}", slug: "team-#{letter}")
      SlateMatchup.create!(slate: slate, team_slug: team.slug, rank: 7, turf_score: 2.0, status: "pending")
    end
  end

  # Run the block against `vault` instead of the chain. FakeVault#entry_pda
  # already returns a string, so the base58 encoder is the identity here.
  #
  # Re-entrant: a request made from inside the double (the concurrent-duplicate
  # tests) runs under the stubs already in place. Minitest's stub does not nest
  # on one method; the inner block's restore would delete the outer's.
  def on_chain(vault, &block)
    return yield if @on_chain

    begin
      @on_chain = true
      Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
        Solana::Keypair.stub :encode_base58, ->(value) { value.to_s } do
          Solana::Vault.stub :new, vault, &block
        end
      end
    ensure
      @on_chain = false
    end
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
  #
  # A query answered from the query cache COUNTS. In an integration test the
  # cache outlives the request, so a repeated request is served almost entirely
  # from it; skipping cached hits measured a 14-query endpoint as 2 and would
  # have hidden any N+1 the first request had already warmed.
  def count_queries(&block)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION])
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
