require "test_helper"

# THE UNCARDED-MODAL LIST IS WRITTEN TWICE, SO IT MUST BE ASSERTED ONCE.
#
# app/controllers/admin_controller.rb and docs/AUTH.md each name the modal ids
# that have no card in the engine style guide yet. Two copies of one fact, and
# the 17-modal migration shortens BOTH on every port — so they drift by
# construction, not by accident.
#
# WHY THIS EXISTS, precisely. On 2026-08-25 PR #413 and PR #415 both edited that
# list off the same base. The controller hunk CONFLICTED and a human resolved it.
# The AUTH.md hunk AUTO-MERGED CLEAN to a list that still contained an id the
# resolved controller said had been removed — git flagged nothing, no test looked,
# and the doc contradicted the code in the same commit. It took a reviewer reading
# both by eye to catch it, on a PR whose CI was fully green.
#
# The loud half of a conflict gets attention. The silent half is the one that
# ships. This test is the eye that reads both.
class ModalDeprecationListAgreementTest < ActiveSupport::TestCase
  CONTROLLER = Rails.root.join("app/controllers/admin_controller.rb")
  AUTH_DOC   = Rails.root.join("docs/AUTH.md")

  # The controller names them bare inside the parenthetical that follows
  # "no card in the engine"; AUTH.md backticks them. Both are read from the same
  # sentence so a rewording that moves the list is a loud failure here rather
  # than a silent pass.
  def controller_ids
    body = CONTROLLER.read[/no card in the engine\s*\n?\s*#\s*guide \((.*?)\)/m, 1]
    assert body, "admin_controller.rb no longer states which modal ids lack an engine card"
    body.gsub(/#|\s/, "").split(",").reject(&:empty?).sort
  end

  def auth_doc_ids
    body = AUTH_DOC.read[/modal ids have no card in the engine guide yet \((.*?)\)/m, 1]
    assert body, "docs/AUTH.md no longer states which modal ids lack an engine card"
    body.scan(/`([a-z0-9-]+)`/).flatten.sort
  end

  test "the controller and AUTH.md name the SAME uncarded modals" do
    assert_equal controller_ids, auth_doc_ids,
                 "the two copies of the uncarded-modal list disagree. One of them was edited and the " \
                 "other was not — most likely a clean auto-merge over a hunk that a sibling PR " \
                 "changed. Reconcile both, and check which is right rather than which is newer."
  end

  test "each list's stated COUNT matches the ids it goes on to name" do
    stated_controller = CONTROLLER.read[/(\d+) of the modal ids below/, 1].to_i
    stated_doc        = AUTH_DOC.read[/(\d+) modal ids have no card/, 1].to_i

    assert_equal controller_ids.length, stated_controller,
                 "admin_controller.rb says #{stated_controller} but names #{controller_ids.length}"
    assert_equal auth_doc_ids.length, stated_doc,
                 "docs/AUTH.md says #{stated_doc} but names #{auth_doc_ids.length}"
  end

  # Guard the guard: both readers must actually find a list. A regex that stopped
  # matching would make the comparison above trivially true on two empty arrays.
  test "both readers find a non-empty list" do
    assert_not_empty controller_ids
    assert_not_empty auth_doc_ids
  end
end
