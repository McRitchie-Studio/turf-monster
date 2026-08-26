require "test_helper"

# [integration] Both halves of the age gate are registered on the modal host.
#
# THE FAILURE THIS EXISTS FOR is one this app has already shipped once. Until
# 2026-08-19 layouts/modal_preview listed the age modal in its gallery but had no
# <template x-if> for the id, so opening it rendered an EMPTY card — a working
# modal with nothing in it, which reads as a styling bug rather than a missing
# partial and therefore gets ignored rather than reported.
#
# The 2026-08-26 adoption doubles that risk: the birthday card now SWAPS to
# 'age-gate' on the server's underage verdict, so an unregistered gate id turns
# the refusal — the one path a person cannot retry their way out of — into that
# same empty card. Register both or neither.
class BirthdayGateRegistrationTest < ActionDispatch::IntegrationTest
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

  test "the engine factory ships at layout level, where a cloned script cannot" do
    html = app_page

    # The host mounts cards through <template x-if>, and a cloned <script> never
    # runs — so a factory shipped INSIDE the card is defined only in markup that
    # never executes. The card would mount against an undefined function and
    # every binding on it would silently no-op.
    # Assert the ASSIGNMENT, not the name. The name also appears in the tombstone
    # comment left where this app's own factory used to live in
    # shared/_alpine_factories — and that comment ships to the page, so a bare
    # name match stayed green with the assets partial deleted outright. Caught by
    # mutation; the same shape of trap as an ERB comment reasoning about the code
    # it sits above.
    assert_includes html, "window.birthdayModal = function",
      "studio/_birthday_assets must render at layout level"
    assert_not_includes html, "window.ageVerifyModal = function",
      "this app's own factory was deleted with the fork"
  end

  test "every opener names the adopted id" do
    html = app_page

    assert_not_includes html, "open('age-verify'",
      "an opener still names the retired id — it would open an empty card"
    assert_includes html, "open('birthday'",
      "the onboarding chain and the contest board both open the DOB card by id"
  end

  test "the admin modal gallery registers both halves too" do
    # The gallery is a SECOND registration list in a second layout, which is
    # exactly how the 2026-08-19 gap happened: the id was listed in the gallery's
    # index while the layout that renders it had no template for it.
    log_in_as(users(:alex))
    get admin_modals_path
    assert_response :success

    assert_includes response.body, "$store.modals.current().id === 'birthday'"
    assert_includes response.body, "$store.modals.current().id === 'age-gate'"
  end
end
