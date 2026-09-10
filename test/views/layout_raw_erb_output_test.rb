# frozen_string_literal: true

require "test_helper"

# [component] No rendered turf page may carry a raw ERB sequence in its OUTPUT.
#
# THE SIBLING GUARD IS STATIC; THIS ONE IS NOT. test/views/script_comment_leak_test.rb
# reads the view SOURCE and refuses an ERB sequence inside a JavaScript comment. It
# is the right shape for the hazard, and it is blind to one thing by construction:
# the ESCAPE form is legal ERB, so a source-level rule has to be told to refuse it.
# This test needs no telling — it asks the only question that ultimately matters,
# which is what actually reached the page.
#
# WHAT IT WOULD HAVE CAUGHT. layouts/application.html.erb carried
#
#     // <%%= render "studio/modals/host" %> below.
#
# inside a script block: a comment describing the modal host, with its tag escaped
# so ERB would not run it. That is correct ERB and the page worked, which is why it
# survived on origin/accepted and origin/main. But <%% renders a literal <% , so
# every turf page shipped the raw string `<%= render "studio/modals/host" %>` in its
# body — and a raw ERB tag in page output is exactly the string other guards in this
# ecosystem scan for. It was rewritten as prose rather than allowlisted.
#
# WHY THE WHOLE LAYOUT AND NOT THE ONE LINE. Pinning that line would pin the fix,
# not the property. The property is that the page output contains no ERB, and it can
# regress from any partial the layout pulls in.
class LayoutRawErbOutputTest < ActionDispatch::IntegrationTest
  ERB_SEQUENCES = ["<%", "%>"].freeze

  test "a rendered page emits no raw ERB sequence" do
    get root_path
    follow_redirect! while response.redirect?

    assert_response :success
    assert_operator response.body.length, :>, 5_000,
                    "the page came back too small to have rendered the layout — this test would " \
                    "pass on an error page for the same reason an empty one does"
    assert_includes response.body, "<script",
                    "the layout's inline JavaScript is where the escaped-tag hazard lives. If no " \
                    "script block reached the output, this test is not looking at the surface it " \
                    "was written for"

    # Reported as a WINDOW around the hit, not with assert_not_includes: that
    # prints the entire page body on failure (735KB when this was proven), which
    # buries the one line a reviewer needs under the haystack it was found in.
    offenders = ERB_SEQUENCES.filter_map do |sequence|
      at = response.body.index(sequence)
      next if at.nil?

      "#{sequence} at byte #{at}: ...#{response.body[[at - 90, 0].max...(at + 90)].strip}..."
    end

    assert_empty offenders,
                 "a raw ERB sequence reached the rendered page. The usual cause is a comment " \
                 "that ESCAPED a tag to describe it: the escape is legal ERB and the page still " \
                 "works, but it emits the tag as literal text on every render, and a raw tag in " \
                 "page output is what other guards in this ecosystem scan for. Describe the tag " \
                 "in words instead of escaping it:\n  #{offenders.join("\n  ")}"
  end
end
