require "test_helper"

# [integration] Both halves of the age gate are registered on the modal host.
#
# THE FAILURE THIS EXISTS FOR is one this app has already shipped once. Until
# 2026-08-19 layouts/modal_preview listed the age modal but had no
# <template x-if> for the id, so opening it rendered an EMPTY card — a working
# modal with nothing in it, which reads as a styling bug rather than a missing
# partial and therefore gets ignored rather than reported. That layout was
# deleted on 2026-09-09 and this asserts against the one that remains; the
# failure mode is a property of registering by id, not of that layout.
#
# The 2026-08-26 adoption doubles that risk: the birthday card now SWAPS to
# 'age-gate' on the server's underage verdict, so an unregistered gate id turns
# the refusal — the one path a person cannot retry their way out of — into that
# same empty card. Register both or neither.
class BirthdayGateRegistrationTest < ActionDispatch::IntegrationTest
  include PageModuleGraph

  def app_page
    log_in_as(users(:alex))
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success
    response.body
  end

  # Read the REGISTERED ids off the <template x-if> elements, not off a
  # substring. Every opener in the page mentions its id too ("open('birthday')"),
  # so a substring search answers "is this id mentioned" — a different question,
  # and one that stays true with the registration deleted.
  def registered_ids(html)
    Nokogiri::HTML(html).css("template[x-if]").filter_map { |t|
      t["x-if"][/\A\$store\.modals\.current\(\)\.id === '([a-z0-9-]+)'\z/, 1]
    }
  end

  test "the app layout registers BOTH the birthday card and the gate it swaps to" do
    ids = registered_ids(app_page)

    assert_includes ids, "birthday", "the DOB card has no host registration"
    assert_includes ids, "age-gate",
      "the birthday card swaps here on a refusal; unregistered, the refusal " \
      "renders an EMPTY card (registered: #{ids.inspect})"
  end

  test "the retired age-verify id is gone from the host" do
    assert_not_includes registered_ids(app_page), "age-verify",
      "modals/_age_verify was deleted; a registration for its id resolves nothing"
  end

  # THE FACTORY REACHES THE PAGE. The host mounts cards through
  # <template x-if>, and a cloned <script> never runs, so a factory shipped
  # INSIDE the card is defined only in markup that never executes: the card
  # mounts against an undefined function and every binding on it silently
  # no-ops. studio/alpine_scopes publishes the factory from the studio/birthday
  # module, so the page has to import it, and every module from there to the
  # card's has to be pinned by the page's importmap and served by this app.
  test "the page loads the module that holds the birthdayModal factory" do
    html = app_page

    assert_not_includes html, "window.ageVerifyModal = function",
      "this app's own factory was deleted with the fork"
    assert_includes page_modules(html, from: "studio/alpine_scopes"), "studio/birthday"
  end

  test "every opener names the adopted id" do
    html = app_page

    assert_not_includes html, "open('age-verify'",
      "an opener still names the retired id — it would open an empty card"
    assert_includes html, "open('birthday'",
      "the onboarding chain and the contest board both open the DOB card by id"
  end

  # A gallery counterpart to the app-layout test above was retired with
  # /admin/modals on 2026-09-09. It asserted the SAME register-both-or-neither
  # invariant against the gallery's own second registration list — and that list
  # is exactly what made the 2026-08-19 gap possible. With one registration
  # surface left, the test at the top of this file is the whole guard.
end
