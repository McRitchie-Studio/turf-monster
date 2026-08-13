require "test_helper"

# The sign-in email's LAYERED banner — this app's artwork with the greeting
# drawn on as live HTML rather than baked into the picture.
#
# turf-monster defines its own UserMailer, so nothing in the engine's suite can
# speak for this app: the engine's tests exercise the engine's mailer, which is
# never loaded here. The division of labour these guards protect is that the
# MAILER supplies who the recipient is and /admin/emails supplies what the
# banner says about them — a mailer that hands over a finished header takes the
# wording away from the operator, whose fields then accept edits no inbox sees.
class UserMailerTest < ActionMailer::TestCase
  def render(email)
    message = UserMailer.magic_link(email, "token-for-test-1234")
    [(message.html_part&.body || message.body).to_s, message]
  end

  def banner_header(html) = html[/font-weight:700;color:#ffffff;">\s*([^<]+)/, 1]&.strip

  # --- it layers at all -----------------------------------------------------

  # THE WHOLE POINT OF THE TASK. This app registers its OWN flat .jpg for
  # magic_link, and studio-engine 0.42 gated the layered background on whether
  # the ENGINE owned the flat artwork — so no configuration could make this app
  # layer. 0.43 records whose the background is at registration instead.
  test "the banner is layered, not the flat image" do
    html, = render(users(:alex).email)

    assert_includes html, "background-size:cover",
      "a layered banner draws the artwork as a background, not an <img>"
    assert_includes html, "v:rect",
      "Outlook renders through Word and needs the VML block or the banner is blank there"
  end

  # INHERITED ON PURPOSE — "island now, gator later" (Mr. McRitchie, 2026-08-13).
  #
  # The guard here asserted that THIS APP owns the registered file
  # (Rails.root.join("app/assets/images", entry.background).exist?) and it was
  # RED, correctly: turf owns no layered artwork, so the sign-in email draws
  # studio-engine's shared violet island. That is now the decision rather than
  # the defect — turf's own background is deferred to
  # https://mcritchie.studio/tasks/turf-owns-its-banner-artwork.
  #
  # What this does NOT go back to is the substring check that ownership
  # assertion replaced ("does the resolved URL contain magic-link-background").
  # That passed whether the file came from this app or from the gem, so it was
  # blind to the one thing the decision is about — and it is the guard that let
  # the engine's wordmark ship beside it unnoticed. This one is not blind: it
  # names the engine as the source and goes red if that stops being true.
  #
  # Two properties, deliberately different in kind:
  #
  #   1. IT RESOLVES. The one an inbox feels. EmailCatalog#asset_path rescues
  #      StandardError to nil, and _layered_banner.html.erb gates every
  #      background path — the td attribute, the CSS, the whole VML block — on
  #      background_url.present?. So an upstream rename or removal raises
  #      NOTHING: the email quietly ships a flat theme-colour box with the
  #      greeting on it. Asking the pipeline unrescued is what turns that
  #      silence into a red test.
  #   2. IT IS THE ENGINE'S, AND THAT IS A CHOICE. Asserted positively against
  #      the gem's own asset tree, so "inherited" is something the suite checks
  #      rather than a comment someone has to take on faith.
  #
  # WHEN THE GATOR LANDS: committing app/assets/images/emails/
  # magic-link-background.gif fires the last assertion below, by design.
  # Replace the two provenance assertions with the ownership one this task
  # relaxed —
  #   assert Rails.root.join("app/assets/images", entry.background).exist?
  # — and delete this paragraph. The resolution assertion stays either way.
  # OWNERSHIP, flipped as the tripwire that used to live here instructed. This
  # asserted the file was still studio-engine's and REFUTED that turf owned it,
  # because turf deliberately inherited the island loop. Turf now commits its own
  # copy — Mr. McRitchie's call, keeping the Studio artwork for now and swapping
  # in turf's later — so the provenance flipped and the assertion flips with it.
  #
  # A copy rather than a re-registered gem path, because owning the file is what
  # makes "swap it later" a one-file change, and it is what stops the silent
  # inheritance this entry had before: the same NAME resolved from studio-engine
  # and nothing on the page or in the email could tell you which one shipped.
  test "this app owns the background it registers" do
    entry = Studio::EmailCatalog.entry("magic_link")

    assert entry.layered?, "a host that registers a background is asking to layer"

    resolved =
      begin
        ActionController::Base.helpers.asset_path(entry.background)
      rescue StandardError
        nil # Sprockets raises AssetNotFound here; the message below says the cost
      end
    assert resolved.present?,
      "#{entry.background} is registered but does not resolve in this app's asset " \
      "pipeline. Nothing raises in production — the layered banner is gated on " \
      "background_url.present?, so the sign-in email would ship a bare colour box."

    assert Rails.root.join("app/assets/images", entry.background).exist?,
      "#{entry.background} is registered but this app does not own it — it is " \
      "resolving from studio-engine, so the sign-in email ships the ENGINE's " \
      "artwork. Add the file to app/assets/images or register the app's own."
  end

  # THE SAME GUARD FOR THE LOGO, because the logo is where the leak actually
  # shipped: this entry registered "emails/logo-horizontal.png", turf has no such
  # file, and Sprockets served studio-engine's — so the sign-in email carried the
  # McRITCHIE STUDIO wordmark. The alt text said "Turf Monster" the whole time,
  # which is what made it invisible. A URL-substring assertion cannot see this;
  # only the file on disk separates ours from the gem's.
  test "this app's own logo is what ships" do
    entry = Studio::EmailCatalog.entry("magic_link")
    skip "this entry ships no logo" if entry.logo.blank?

    path = Rails.root.join("app/assets/images", entry.logo)
    assert path.exist?,
      "#{entry.logo} is registered but this app does not own it — it is resolving " \
      "from studio-engine, so the sign-in email ships the ENGINE's mark."
  end

  # The wordmark by name, so a re-introduction is caught however it gets there —
  # a reverted line, a merge, or an operator upload that happens to be named for
  # the engine's asset.
  test "the engine's wordmark does not ride along" do
    html, = render(users(:alex).email)

    refute_includes html, "logo-horizontal",
      "that asset is studio-engine's McRitchie Studio wordmark"
  end

  # --- who it greets --------------------------------------------------------

  test "a recipient with a handle is greeted by it" do
    user = users(:alex)

    html, = render(user.email)

    assert_equal "Welcome #{user.username}!", banner_header(html)
  end

  # A magic link is often the FIRST thing a stranger receives — there is no
  # account and no name — so this is a live path, not an edge case. "Welcome !"
  # is what renders without the name-free header.
  test "a stranger gets the name-free header" do
    html, = render("nobody-here@example.test")

    assert_equal "Your Magic Link", banner_header(html)
    refute_includes html, "Welcome !"
  end

  # display_name falls back to the email local part, so it ALWAYS returns
  # something — using it would greet a handle-less recipient with a fragment of
  # their own address instead of the name-free header.
  test "a recipient with no handle is not greeted by their email address" do
    user = users(:alex)
    user.update_columns(username: nil, name: nil)

    html, = render(user.email)

    # Scoped to the HEADER, not the document: the body legitimately prints the
    # full address ("This link is for alex@…"), so a whole-page refutation would
    # fail on correct output.
    refute_includes banner_header(html), user.email.split("@").first
    assert_equal "Your Magic Link", banner_header(html)
  end

  # --- it is still a sign-in email ------------------------------------------

  test "the token still reaches the recipient" do
    html, message = render(users(:alex).email)

    assert_includes html, "token-for-test-1234", "the link is the point of the email"
    assert_equal [users(:alex).email], message.to
  end

  test "the other emails are untouched by this change" do
    message = UserMailer.email_verification(users(:alex), "token-for-test-1234")
    html = (message.html_part&.body || message.body).to_s

    refute_includes html, "background-size:cover",
      "only magic_link registered layered artwork; the rest still send their flat banners"
  end
end
