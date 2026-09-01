require "test_helper"

# ONE Phantom row, in every state.
#
# The bug this locks down: the two wallet modals each painted TWO Phantom rows
# on a phone, because two guards that never consulted each other were both true
# at once. "Phantom — INSTALL" came from the not-detected list (Phantom is not
# injected into a mobile browser, so it always showed) and "Open in Phantom
# app" came from a bare user-agent test. On any phone both fired, and the row on
# top was the broken one — you cannot install a browser extension on iOS Safari,
# so its download link was a dead end. Inside Phantom's own in-app browser the
# pair inverted: a working detected row PLUS a deep link offering to leave
# Phantom to open Phantom.
#
# These assertions read the ERB source rather than a rendered response on
# purpose. The guards are Alpine getters evaluated in the browser against
# navigator.userAgent, so no server render can distinguish the mobile case —
# the source is where the contract lives and the cheapest place to fail loudly.
# ERB comments are stripped first: every prose block below the fold names these
# same identifiers, and an assertion that matched the comment would stay green
# through a deletion of the code it claims to cover.
#
# 2026-08-29 (adopt-turf-engine-picker): THE PICKER IS THE ENGINE'S NOW, so the
# picker half reads studio-engine's source RESOLVED — a File.read of the old app
# path is a read of a file that no longer exists, and hardcoding the gem path
# instead would encode how the engine happens to be installed. The guarantee
# still belongs here: it is a bug THIS APP shipped, and this app is what a
# regression would be visible in. The setup card is still this app's own file.
class WalletPickerSinglePhantomTest < ActionDispatch::IntegrationTest
  SETUP = "app/views/modals/_wallet_setup.html.erb".freeze

  # Source with ERB comments removed, so a match is code and never prose.
  def code(path)
    Rails.root.join(path).read.gsub(/<%#.*?%>/m, "")
  end

  # The picker that actually renders, with ERB comments AND the // comments in
  # its x-data removed — the engine names canDeepLink, showPhantomDeepLink and
  # missingInstalls in prose that ships to the page.
  def picker
    ResolvedWalletPicker.code
  end

  # --- the picker (guest "Connect Wallet") --------------------------------

  test "the picker has exactly one Phantom deep-link trigger" do
    triggers = picker.scan(/@click="deepLink\(\)"/)
    assert_equal 1, triggers.length,
                 "expected a single deep-link row in the picker, found #{triggers.length} — " \
                 "a second one is the duplicate-Phantom bug coming back"
  end

  test "the picker's deep-link row is gated on Phantom's absence, not on the user agent alone" do
    body = picker
    row = body[/<button\b[^>]*@click="deepLink\(\)"[^>]*>/m]
    assert row.present?, "could not locate the deep-link row — did the element change?"

    guard = row[/x-show="([^"]+)"/, 1]
    assert_equal "showPhantomDeepLink", guard,
                 "the deep-link row must consult whether Phantom is already reachable; " \
                 "x-show=\"isMobile\" alone is what painted it beside a detected Phantom " \
                 "inside Phantom's in-app browser"

    getter = body[/get showPhantomDeepLink\(\)\s*\{(.*?)\n\s*\},/m, 1]
    assert getter.present?, "showPhantomDeepLink getter is missing"
    assert_match(/this\.isMobile/, getter,
                 "the deep link is a mobile-only path — the getter must require isMobile")
    assert_match(/!\s*this\.hasWallet\('Phantom'\)/, getter,
                 "the getter must suppress itself when Phantom is already injected, " \
                 "or the in-app browser gets a detected row AND a deep link")
  end

  test "the picker drops Phantom's install row on mobile" do
    getter = picker[/get missingInstalls\(\)\s*\{(.*?)\n\s*\},/m, 1]
    assert getter.present?, "missingInstalls getter is missing"
    assert_match(/self\.isMobile\s*&&.*?i\.name\s*===\s*'Phantom'/, getter,
                 "a phone has no extension to install, so Phantom's download-page row " \
                 "must be filtered out — leaving it is the second row from the bug report")
    # The engine adds a conjunct the fork did not have, and it is not cosmetic:
    # the install row is suppressed ONLY when a deep link can replace it. Drop it
    # and an app with no startPhantomDeepLink hands a phone Phantom's INSTALL row
    # — the very iOS dead end this file exists to kill — because both getters read
    # canDeepLink and flip together. (Corrected 2026-08-30: this comment used to
    # say such a phone gets "no Phantom path at all", which is backwards; measured
    # in a browser under adopt-engine-phantom-deeplink.) This app DOES
    # define it — since adopt-engine-phantom-deeplink by rendering
    # solana_studio/phantom_deeplink from shared/_alpine_factories (it came from
    # studio-engine until /tasks/turf-rides-gem-modals), pinned on the
    # RENDERED page in wallet_picker_adoption_test and phantom_deeplink_adoption_test
    # — which is what makes the suppression here behave as it did before the adoption.
    assert_match(/self\.canDeepLink/, getter,
                 "the install row must only be suppressed when a deep link can " \
                 "replace it — without this a deep-link-less consumer loses Phantom entirely")
    assert_no_match(/(?:self|this)\.isMobile\s*&&\s*i\.name\s*===\s*'(?:Solflare|Backpack)'/, getter,
                    "Solflare and Backpack keep their install rows: we ship no deep link " \
                    "for either, so the download page is still their only path")
  end

  test "no row in the picker is gated on the bare user-agent test" do
    assert_no_match(/x-show="isMobile"/, picker,
                    "isMobile alone cannot tell a Phantom-less browser from Phantom's own; " \
                    "every mobile row must go through a guard that asks about the wallet too")
  end

  # --- the post-auth setup card -------------------------------------------

  test "the setup card's Phantom branches are mutually exclusive" do
    guards = code(SETUP).scan(/<template x-if="([^"]*phantomPresent[^"]*)">/).flatten
    assert_equal ["phantomPresent",
                  "!phantomPresent && isMobile",
                  "!phantomPresent && !isMobile"].sort,
                 guards.sort,
                 "the card must offer exactly three Phantom branches — reachable, phone, " \
                 "desktop — and no two of them may be true at once"
  end

  test "the setup card has exactly one Phantom deep-link trigger, inside the mobile branch" do
    body = code(SETUP)
    assert_equal 1, body.scan(/@click="deepLink\(\)"/).length,
                 "a second deep-link row is the duplicate-Phantom bug coming back"

    mobile_branch = body[/<template x-if="!phantomPresent && isMobile">(.*?)<\/template>/m, 1]
    assert mobile_branch.present?, "could not locate the mobile Phantom branch"
    assert_match(/@click="deepLink\(\)"/, mobile_branch,
                 "on a phone the deep link IS the Phantom row — it must live in that " \
                 "branch, not float below the card as a second entry")
  end

  test "no row in the setup card is gated on the bare user-agent test" do
    assert_no_match(/x-show="isMobile"/, code(SETUP),
                    "the standalone 'Open in Phantom app' row was gated this way and " \
                    "showed alongside every other Phantom row")
  end

  # --- the failure mode no markup assertion above can see -----------------
  #
  # A single double quote inside the double-quoted x-data closes the attribute
  # early; Alpine then mounts the component as a silent no-op, and every
  # assertion in this file still passes while the modal is dead in a real
  # browser. For the PICKER that attribute is now the engine's, plus this app's
  # extra_data fragment — the only half this app can still break — so the guard
  # moved to test/views/wallet_picker_adoption_test.rb, where it reads
  # WalletPickerHelper's fragment DIRECTLY. Reading it out of the rendered
  # attribute, as the version here did, cannot work: any extractor bounded by
  # the quote character returns a string that can never contain one, so the
  # assertion is inert. Mutation is what showed that.

  # --- render smoke --------------------------------------------------------

  test "both wallet modals still render through the admin gallery" do
    log_in_as users(:alex)

    get admin_modal_preview_path(modal_id: "wallet-connect")
    assert_response :success
    assert_includes response.body, "Connect Wallet"

    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success
  end
end
