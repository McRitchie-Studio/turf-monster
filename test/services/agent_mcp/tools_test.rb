require "test_helper"

# [unit] The MCP tool registry (app/services/agent_mcp/tools.rb): what a client
# is told about each tool, and which agent API operation each one runs.
class AgentMcp::ToolsTest < ActiveSupport::TestCase
  Ops = Api::V1::Operations

  READS = %w[get_me list_contests get_contest get_leaderboard list_my_entries get_entry].freeze
  WRITES = %w[submit_entry edit_entry].freeze

  def definitions(version = AgentMcp::Protocol::LATEST)
    AgentMcp::Tools.definitions(version).index_by { |tool| tool[:name] }
  end

  test "the tools are the six reads and the two writes, by these names" do
    assert_equal READS + WRITES, AgentMcp::Tools::ALL.map(&:name)
    assert_equal READS, AgentMcp::Tools::ALL.reject(&:writes?).map(&:name)
    assert_equal WRITES, AgentMcp::Tools::ALL.select(&:writes?).map(&:name)
  end

  test "each tool runs the operation its REST endpoint runs" do
    expected = {
      "get_me" => Ops::GetMe, "list_contests" => Ops::ListContests, "get_contest" => Ops::GetContest,
      "get_leaderboard" => Ops::GetLeaderboard, "list_my_entries" => Ops::ListEntries, "get_entry" => Ops::GetEntry,
      "submit_entry" => Ops::SubmitEntry, "edit_entry" => Ops::EditEntry
    }

    assert_equal expected, AgentMcp::Tools::ALL.to_h { |tool| [tool.name, tool.operation] }

    # …and REST names the same eight, so neither surface has work of its own.
    controllers = Dir[Rails.root.join("app/controllers/api/v1/*_controller.rb")].map { |path| File.read(path) }.join
    expected.each_value do |operation|
      assert_includes controllers, "run_operation Operations::#{operation.name.demodulize}",
                      "#{operation} is not what an /api/v1 action runs"
    end
  end

  test "names are snake_case and within the specification's limits" do
    AgentMcp::Tools::ALL.each do |tool|
      assert_match(/\A[a-z][a-z0-9_]{0,127}\z/, tool.name)
    end
  end

  test "every tool has a description, an object schema that takes no unknown argument, and honest annotations" do
    definitions.each do |name, tool|
      assert tool[:description].length > 60, "#{name} needs a description a model can choose by"
      assert_no_match(/\n/, tool[:description])

      schema = tool[:inputSchema]
      assert_equal "object", schema[:type]
      assert_equal false, schema[:additionalProperties]
      assert_empty schema[:required] - schema[:properties].keys, "#{name} requires an argument it does not define"
      schema[:properties].each do |argument, property|
        assert property[:type].present?, "#{name}.#{argument} has no type"
        assert property[:description].present?, "#{name}.#{argument} has no description"
      end

      writes = WRITES.include?(name)
      assert_equal({ readOnlyHint: !writes, destructiveHint: writes, idempotentHint: true, openWorldHint: false },
                   tool[:annotations].except(:title), name)
    end
  end

  test "the schemas, argument by argument" do
    tools = definitions
    required = tools.transform_values { |tool| tool[:inputSchema][:required] }
    arguments = tools.transform_values { |tool| tool[:inputSchema][:properties].keys }

    assert_equal [], arguments["get_me"]
    assert_equal %w[status limit offset], arguments["list_contests"]
    assert_equal [], required["list_contests"]
    assert_equal %w[open settled], tools["list_contests"][:inputSchema][:properties]["status"][:enum]
    assert_equal %w[contest_slug], arguments["get_contest"]
    assert_equal %w[contest_slug], required["get_contest"]
    assert_equal %w[contest_slug limit offset], arguments["get_leaderboard"]
    assert_equal %w[contest_slug], required["get_leaderboard"]
    assert_equal %w[contest_slug limit offset], arguments["list_my_entries"]
    assert_equal [], required["list_my_entries"]
    assert_equal %w[entry_slug], required["get_entry"]
    assert_equal %w[contest_slug matchup_ids idempotency_key allow_usdc], arguments["submit_entry"]
    assert_equal %w[entry_slug matchup_ids], required["edit_entry"]
  end

  test "submit_entry requires an idempotency key as an argument and defaults to token only" do
    schema = definitions["submit_entry"][:inputSchema]

    assert_equal %w[contest_slug matchup_ids idempotency_key], schema[:required]
    assert_equal "boolean", schema[:properties]["allow_usdc"][:type]
    assert_equal false, schema[:properties]["allow_usdc"][:default]

    key = schema[:properties]["idempotency_key"]
    assert_equal "string", key[:type]
    # The published pattern admits exactly what the record's own format does.
    pattern = Regexp.new(key[:pattern].sub(/\A\^/, '\A').sub(/\$\z/, '\z'))
    ["a", "550e8400-e29b-41d4-a716-446655440000", "~!x", "has space", "tab\there", "", "é"].each do |candidate|
      assert_equal candidate.match?(ApiEntryRequest::KEY_FORMAT), candidate.match?(pattern), candidate.inspect
    end
    assert_equal 255, key[:maxLength]
  end

  test "the paging limits published are the ones the operations enforce" do
    limit = definitions["list_contests"][:inputSchema][:properties]["limit"]

    assert_equal Api::V1::Pagination::MAX_LIMIT, limit[:maximum]
    assert_includes limit[:description], Api::V1::Pagination::DEFAULT_LIMIT.to_s
  end

  test "a top-level title is published from 2025-06-18; annotations carry one in every revision" do
    assert_nil definitions("2025-03-26")["get_me"][:title]
    assert_equal "Who am I playing as", definitions("2025-03-26")["get_me"][:annotations][:title]
    assert_equal "Who am I playing as", definitions("2025-06-18")["get_me"][:title]
    assert_equal "Who am I playing as", definitions("2025-11-25")["get_me"][:title]
  end

  # --- the adapter: argument names in, operation out --------------------------------

  class Recorder
    cattr_accessor :seen

    def self.call(**options)
      self.seen = options
      :outcome
    end
  end

  def tool(**options)
    AgentMcp::Tool.new(name: "probe", title: "Probe", description: "d", operation: Recorder, writes: false, **options)
  end

  def call(tool, arguments)
    tool.call(user: :user, api_key: :key, arguments: arguments, writable: true)
  end

  test "an argument reaches the operation under the operation's own name" do
    probe = tool(arguments: { contest_slug: { schema: {}, required: true, param: :slug }, limit: { schema: {} } })

    assert_equal :outcome, call(probe, { "contest_slug" => "wk4", "limit" => 5 })
    assert_equal({ "slug" => "wk4", "limit" => 5 }, Recorder.seen[:params])
    assert_equal [:user, :key, true], Recorder.seen.values_at(:user, :api_key, :writable)
  end

  test "a keyword argument is passed beside the params, and as nil when left out" do
    probe = tool(arguments: { idempotency_key: { schema: {}, required: true } }, keywords: { idempotency_key: :idempotency_key })

    call(probe, { "idempotency_key" => "k1" })
    assert_equal "k1", Recorder.seen[:idempotency_key]
    assert_empty Recorder.seen[:params]

    call(probe, {})
    assert_nil Recorder.seen.fetch(:idempotency_key)
  end

  test "an argument the tool does not have is a bad request that names it and lists the real ones" do
    probe = tool(arguments: { contest_slug: { schema: {}, required: true, param: :slug } })

    error = assert_raises(ActionController::BadRequest) { call(probe, { "slug" => "wk4" }) }

    assert_equal "probe has no argument named slug. It takes: contest_slug.", error.message
  end

  test "a required argument left out, or null, is a bad request that names it" do
    probe = tool(arguments: { contest_slug: { schema: {}, required: true, param: :slug } })

    assert_equal "contest_slug is required.", assert_raises(ActionController::BadRequest) { call(probe, {}) }.message
    assert_raises(ActionController::BadRequest) { call(probe, { "contest_slug" => nil }) }
  end
end
