require "test_helper"

# [unit] THE GUIDE AND THE APP NAME THE SAME API.
#
# /agents, /agents/guide.md and /llms.txt tell an agent which requests to send
# and which error codes it will be answered with. An agent cannot tell a
# documented route that does not exist from one that does until it has spent a
# player's turn finding out, so this holds the pages to the app in both
# directions:
#
#   * every `VERB /api/...` the pages name is a route the app draws, to a real
#     controller (the JSON 404 catch-all does not count as drawing one);
#   * every API route the app draws is in the guide;
#   * every error code in the guide's table is one the app's source emits;
#   * every error code the app's API source emits is in the guide's table;
#   * every MCP tool the pages name is in the registry, every registry tool is
#     in the guide, and the REST request the guide pairs a tool with is the one
#     whose action runs that tool's operation.
#
# The code checks are SOURCE scans on purpose. The failure they exist for is a
# new refusal appearing in the app with no row in the guide, and no request a
# test could send would exercise a refusal nobody has written a test for yet.
class AgentGuideGuardTest < ActionDispatch::IntegrationTest
  ROUTE = %r{\b(GET|POST|PATCH|PUT|DELETE) (/api/[A-Za-z0-9_/:.-]*[A-Za-z0-9_])}
  CATCH_ALL_CONTROLLER = "api/v1/errors".freeze

  # Where an API error code can be written down. The agent API has two
  # surfaces over one set of operations: /api/v1 (the controllers) and /mcp
  # (McpController and AgentMcp), and a refusal can be written in either or in
  # the operations both call. All of it is scanned, so a code added anywhere an
  # agent can be answered from needs a row in the guide.
  CODE_SOURCES = %w[
    app/controllers/api/**/*.rb
    app/controllers/mcp_controller.rb
    app/controllers/concerns/api_key_authentication.rb
    app/controllers/concerns/solana_wait_budget.rb
    app/services/api/v1/operations/**/*.rb
    app/services/agent_mcp/**/*.rb
    app/services/entries/**/*.rb
    app/models/entry.rb
    app/models/entry/**/*.rb
    config/initializers/rack_attack.rb
  ].freeze

  # The ways the API's source names a code it answers with.
  EMITTERS = [
    /Refusal\.new\(\s*:(\w+)/,
    /\brefuse\(\s*:(\w+)/,
    /\brender_api_error\(\s*:(\w+)/,
    /\berror\(\s*:(\w+)/,
    /(?<![\w_])code: "(\w+)"/ # the envelope's own key, not `last_error_code:` on a record
  ].freeze

  def fetch(path)
    get path
    assert_response :success
    response.body
  end

  def guide
    @guide ||= fetch(agents_guide_markdown_path)
  end

  def human_page
    @human_page ||= Nokogiri::HTML(fetch(agents_path)).at_css('[data-test="agents-page"]').text
  end

  def named_routes(text)
    text.scan(ROUTE).uniq
  end

  def source_without_comments(path)
    File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
  end

  def api_sources
    CODE_SOURCES.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }.uniq
  end

  # The codes in the guide's "Every error code" table: second column, in code.
  def documented_codes
    table = guide[/^### Every error code\n\n(.*?)\n\n/m, 1]
    assert table, "the guide lost its 'Every error code' table"
    table.lines.drop(2).map { |row| row.split("|")[2].to_s[/`(\w+)`/, 1] }.compact
  end

  def emitted_codes
    codes = api_sources.flat_map do |path|
      source = source_without_comments(path)
      EMITTERS.flat_map { |pattern| source.scan(pattern).flatten }
    end
    codes += ApiKeyAuthentication::AUTH_ERRORS.keys.map(&:to_s)
    codes.uniq
  end

  test "every route the pages name is drawn by the app" do
    named = named_routes(guide) | named_routes(human_page) | named_routes(fetch(llms_txt_path))
    assert_operator named.size, :>=, 8, "the scan found too few routes to be reading the pages"

    missing = named.reject do |verb, path|
      concrete = path.gsub(/:\w+/, "example")
      route = Rails.application.routes.recognize_path(concrete, method: verb)
      route[:controller].start_with?("api/v1/") && route[:controller] != CATCH_ALL_CONTROLLER
    rescue ActionController::RoutingError
      false
    end

    assert_empty missing.map { |pair| pair.join(" ") }, "the pages document routes the app does not draw"
  end

  test "the human page names no route the guide does not" do
    assert_empty named_routes(human_page) - named_routes(guide)
  end

  test "every API route the app draws is in the guide" do
    drawn = Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller].to_s
      next unless controller.start_with?("api/v1/") && controller != CATCH_ALL_CONTROLLER

      path = route.path.spec.to_s.sub("(.:format)", "")
      route.verb.split("|").map { |verb| "#{verb} #{path}" }
    end.flatten.uniq

    assert_operator drawn.size, :>=, 6
    assert_empty drawn.reject { |line| guide.include?("`#{line}`") }, "the app draws API routes the guide does not list"
  end

  test "every error code in the guide is one the app emits" do
    documented = documented_codes
    assert_operator documented.size, :>=, 10
    assert_equal documented.uniq, documented, "a code has two rows"

    assert_empty documented - emitted_codes, "the guide documents error codes the app's source never emits"
  end

  test "every error code the app emits is in the guide" do
    assert_empty emitted_codes - documented_codes, "the app emits error codes the guide has no row for"
  end

  # The operations are where the edit's own refusals are written, and the MCP
  # files are where a second surface could grow codes of its own. If a glob
  # stopped matching, both code tests would go on passing without them.
  test "the scan reaches the operations and both surfaces" do
    scanned = api_sources.map { |path| Pathname(path).relative_path_from(Rails.root).to_s }

    %w[
      app/controllers/api/v1/entries_controller.rb
      app/controllers/mcp_controller.rb
      app/services/api/v1/operations/edit_entry.rb
      app/services/api/v1/operations/submit_entry.rb
      app/services/agent_mcp/server.rb
      app/services/agent_mcp/tool_result.rb
      app/services/entries/api_submission.rb
    ].each { |path| assert_includes scanned, path }

    edit = source_without_comments(Rails.root.join("app/services/api/v1/operations/edit_entry.rb"))
    found = EMITTERS.flat_map { |pattern| edit.scan(pattern).flatten }
    assert_equal %w[contest_cancelled duplicate_lineup], found.sort, "the two refusals the edit adds are no longer seen where they are written"
  end

  # /mcp answers in the SAME envelope codes as /api/v1 and adds none: its own
  # transport refusals (405, the Origin 403, a malformed message) are JSON-RPC
  # errors with numeric codes, which is not this vocabulary. The guide's MCP
  # section says exactly that ("the same codes as the table under Errors"), so
  # a new envelope code written in the MCP files fails here first, by name.
  test "the MCP surface emits no envelope code of its own" do
    mcp = %w[app/controllers/mcp_controller.rb app/services/agent_mcp/**/*.rb]
          .flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }
    assert_operator mcp.size, :>=, 6
    codes = mcp.flat_map { |path| EMITTERS.flat_map { |pattern| source_without_comments(path).scan(pattern).flatten } }.uniq

    assert_equal %w[rate_limited], codes, "a code only /mcp emits needs a decision: a guide row, or a JSON-RPC error instead"
  end

  test "the scan sees the codes it was written to see" do
    # A regex that silently stopped matching would make both code tests pass on
    # an empty set. These four are emitted four different ways.
    %w[invalid_api_key account_frozen not_found rate_limited].each do |code|
      assert_includes emitted_codes, code
    end
  end

  # ── The MCP tools ───────────────────────────────────────────────────────────

  TOOL_NAME = /`((?:get|list|submit|edit|create|delete|update|cancel|withdraw)_[a-z_]+)`/

  def registry_tools
    AgentMcp::Tools::ALL.map(&:name)
  end

  def mcp_section
    section = guide[/^## Playing through MCP\n(.*?)^## /m, 1]
    assert section, "the guide lost its 'Playing through MCP' section"
    section
  end

  # The rows of "The tools": [name, rest request, arguments cell].
  def tool_rows
    table = mcp_section[/^### The tools\n\n(.*?)\n\n/m, 1]
    assert table, "the guide lost its tools table"
    table.lines.drop(2).map { |row| row.split("|").map(&:strip)[1, 3] }
  end

  test "every MCP tool the pages name is in the registry" do
    assert_operator registry_tools.size, :>=, 8
    # Everywhere a tool-shaped name is written, by hand or by the template:
    # the guide's prose, the human page, llms.txt.
    named = [ guide, human_page, fetch(llms_txt_path) ].flat_map { |text| text.scan(TOOL_NAME).flatten }.uniq
    assert_operator named.size, :>=, registry_tools.size, "the scan found too few tool names to be reading the guide"

    assert_empty named - registry_tools, "the pages name MCP tools the registry does not have"
  end

  test "every MCP tool in the registry has a row in the guide, with its arguments" do
    rows = tool_rows.to_h { |name, _rest, arguments| [ name.delete("`"), arguments ] }
    assert_equal registry_tools, rows.keys, "the guide's tools table is not the registry, in order"

    AgentMcp::Tools::ALL.each do |tool|
      schema = tool.input_schema
      required = rows.fetch(tool.name).scan(/\*\*`(\w+)`\*\*/).flatten
      listed = rows.fetch(tool.name).scan(/`(\w+)`/).flatten
      assert_equal schema[:required], required, "#{tool.name}: the bold arguments are not the required ones"
      assert_equal schema[:properties].keys, listed, "#{tool.name}: the arguments listed are not the schema's"
    end
  end

  # The one thing about a tool the guide TYPES: which REST request it stands
  # for. Held to the code: that request's action is the one that runs the
  # operation the tool runs.
  test "the REST request beside each tool is the one that runs the tool's operation" do
    tool_rows.each do |name, rest, _arguments|
      tool = AgentMcp::Tools.find(name.delete("`"))
      verb, path = rest.delete("`").split(" ", 2)
      route = Rails.application.routes.recognize_path(path.gsub(/:\w+/, "example"), method: verb)
      source = File.read(Rails.root.join("app/controllers/#{route[:controller]}_controller.rb"))
      action = source[/^\s*def #{route[:action]}\n(.*?)^\s*end\n/m, 1]

      assert action, "#{rest}: no action #{route[:controller]}##{route[:action]}"
      assert_match(/\brun_operation Operations::#{tool.operation.name.demodulize}\b/, action,
                   "#{name} is paired with #{rest}, whose action does not run #{tool.operation.name}")
    end
  end

  # The two markers the guide quotes are the first words of the text blocks
  # the server really adds; a model matches on them.
  test "the PENDING and RETRY markers in the guide are the ones the server sends" do
    outcome = Api::V1::Operations::Outcome
    pending = AgentMcp::ToolResult.guidance(outcome.new(status: :accepted, body: {}, retry_after: 5))
    retry_note = AgentMcp::ToolResult.guidance(outcome.error(:chain_unavailable, "x", status: :service_unavailable, retry_after: 5))

    quoted = mcp_section.scan(/^- \*\*`([A-Z][A-Z ,:]+)`\*\*/).flatten
    assert_equal 2, quoted.size
    assert pending.start_with?("#{quoted[0]}."), "the guide quotes a pending marker the server does not send"
    assert retry_note.start_with?("#{quoted[1]}."), "the guide quotes a retry marker the server does not send"
  end

  # ── The fields "How to win" reasons from ────────────────────────────────────

  test "every field the strategy section leans on is one the API serializes" do
    serializers = Dir.glob(Rails.root.join("app/serializers/api/v1/*.rb")).map { |path| File.read(path) }.join
    strategy = guide[/^## How to win\n(.*)\z/m, 1]
    fields = strategy.scan(/`([a-z]+(?:_[a-z]+)+)`/).flatten.uniq - %w[contest_locked]

    %w[expected_team_score turf_score games_count payouts entries_count max_entries_per_player].each do |field|
      assert_includes strategy, "`#{field}`", "How to win no longer reasons from #{field}"
    end
    missing = fields.reject { |field| serializers.match?(/\b#{field}:/) }
    assert_empty missing, "How to win names fields no serializer emits"
  end
end
