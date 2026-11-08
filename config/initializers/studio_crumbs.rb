# frozen_string_literal: true

# THE PARENT MAP behind studio/_page_header's crumb trail (studio-engine
# lib/studio/crumbs.rb, docs/PAGE_HEADER.md "Crumbs"). Each page that has children
# is named once here, with its label, its address and its own parent. A page names
# only its parent, and the trail builds itself up the chain:
#
#   <%= render "studio/page_header", title: "Error Logs", crumbs: studio_crumbs(:admin_error_logs) %>
#   <%= render "studio/page_header", title: @error_log.message, crumbs: studio_crumbs(parent: :admin_error_logs) %>
#
# The admin root is the Link Hub, the index of every admin tool. A record page
# (a contest) is drawn with a lambda the view runs with its keyword:
# studio_crumbs(parent: :contest, contest: @contest). Its label is truncated,
# because on a phone the trail gives way to one link to the parent, and that link
# is the label. to_prepare, so a development reload redraws the map.
Rails.application.config.to_prepare do
  Studio.crumbs.clear.draw do
    page :admin, "Admin", :admin_hub_path

    page :admin_dashboard,           "Dashboard",         :admin_dashboard_path,           parent: :admin
    page :admin_error_logs,          "Error Logs",        :admin_error_logs_path,          parent: :admin
    page :admin_outbound_requests,   "Outbound Requests", :admin_outbound_requests_path,   parent: :admin
    page :admin_experiments,         "Experiments",       :admin_experiments_path,         parent: :admin
    page :admin_landing_pages,       "Landing Pages",     :admin_landing_pages_path,       parent: :admin
    page :admin_nfl_weeks,           "NFL Weeks",         :admin_nfl_weeks_path,           parent: :admin
    page :admin_short_links,         "Short Links",       :admin_short_links_path,         parent: :admin
    page :admin_drop_signups,        "Drop Signups",      :admin_drop_signups_path,        parent: :admin
    page :admin_pending_transactions, "Treasury",         :admin_pending_transactions_path, parent: :admin
    page :admin_authorities,         "Authorities",       :admin_authorities_path,         parent: :admin
    page :admin_transactions,        "Transactions",      :admin_transactions_path,        parent: :admin
    page :slates,                    "Slates",            :slates_path,                    parent: :admin

    page :contests, "Contests", :contests_path
    page :contest, ->(contest:) { truncate(contest.name, length: 40) }, ->(contest:) { contest_path(contest) },
         parent: :contests

    page :help,         "Help Center",  :help_path
    page :transparency, "Transparency", :transparency_path
  end
end
