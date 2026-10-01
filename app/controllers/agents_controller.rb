# The two public pages for playing Turf Monster through an AI agent, and the two
# plain-text files an agent reads (docs/AGENT_API.md, "The agent pages").
#
#   GET /agents           the page a person reads: a starter prompt to copy,
#                         three steps, the Claude Code connect command, a short
#                         endpoint table
#   GET /agents/guide     the agent guide, as a page
#   GET /agents/guide.md  the same guide as plain Markdown, the form an LLM reads
#   GET /llms.txt         a pointer to the guide, at the path agents look for
#
# ONE SOURCE FOR THE GUIDE. app/views/agents/guide_source.text.erb is the guide.
# /agents/guide.md serves that string as it is; /agents/guide runs the SAME
# string through MiniMarkdown. There is no second copy to keep in step.
#
# ONE SOURCE FOR THE STARTER PROMPT. app/views/agents/_starter_prompt.text.erb
# is rendered once per request and handed to both the visible block and the copy
# button, so what a person reads is what lands on their clipboard.
#
# ONE SOURCE FOR THE CONNECT COMMAND. `mcp_connect_command` builds the Claude
# Code command that /agents shows and copies and that the guide prints, from the
# host below, the route and the server's own name.
class AgentsController < ApplicationController
  skip_before_action :require_authentication
  # No navbar on the two plain-text responses, so nothing to preload for one.
  skip_before_action :preload_navbar_solana_data, only: %i[guide_markdown llms]

  # The host an agent is told to call. Always production's canonical host, read
  # from the constant production itself falls back to: a prompt copied from a
  # desk or from QA must not send someone's agent to localhost.
  BASE_URL = "https://#{TurfMonster::HostConfig::DEFAULT_APP_HOST}".freeze

  # What stands where the player's key goes in the connect command. One word
  # with no spaces or shell characters, so the command still parses if someone
  # runs it unedited (it then fails with a 401, which is the right failure).
  KEY_PLACEHOLDER = "PASTE_YOUR_API_KEY_HERE".freeze

  helper_method :agent_base_url, :agent_mcp_url, :mcp_connect_command

  def show
    @starter_prompt = render_to_string(partial: "agents/starter_prompt", formats: [ :text ]).strip
  end

  def guide
    @sections = MiniMarkdown.headings(guide_source).select { |heading| heading.level == 2 }
    @guide_html = MiniMarkdown.to_html(guide_source)
  end

  def guide_markdown
    render plain: guide_source, content_type: "text/markdown; charset=utf-8"
  end

  def llms
    render plain: render_to_string(template: "agents/llms", formats: [ :text ], layout: false),
           content_type: "text/plain; charset=utf-8"
  end

  private

  def agent_base_url
    BASE_URL
  end

  def agent_mcp_url
    "#{BASE_URL}#{mcp_path}"
  end

  # `claude mcp add`, as Claude Code documents it for a remote HTTP server with
  # a bearer token (https://code.claude.com/docs/en/mcp, read 2026-10-01, and
  # `claude mcp add --help` on 2.1.286). --header goes LAST: the option takes a
  # list, so placed before the name it would swallow the name and the address.
  # One line, no backslash continuation, so it pastes into any shell.
  def mcp_connect_command(key = KEY_PLACEHOLDER)
    %(claude mcp add --transport http #{AgentMcp::Server::SERVER_INFO.fetch(:name)} #{agent_mcp_url} ) +
      %(--header "Authorization: Bearer #{key}")
  end

  def guide_source
    @guide_source ||= render_to_string(template: "agents/guide_source", formats: [ :text ], layout: false)
  end

  # These four are read by programs: an LLM's fetch tool, curl, a Python client.
  # `allow_browser` answers 406 to any user agent it does not take for a modern
  # browser, which is every one of those. ApplicationController exempts its
  # public pages through this predicate; so does this controller, for all of its
  # actions, since every one of them is a public GET.
  def public_preview_request?
    request.get? || request.head?
  end
end
