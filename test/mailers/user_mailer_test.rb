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

  # OWNERSHIP, not spelling. The previous guard here asserted that the resolved
  # URL CONTAINED "magic-link-background" — which passes whether the file comes
  # from this app or from studio-engine's own asset tree, because registering a
  # name this app does not own still resolves: Sprockets happily serves the
  # gem's copy. So a test named "this app's own background" went green while the
  # engine's artwork shipped, and it is the guard that let the inherited
  # wordmark through beside it.
  #
  # The file on disk is the only thing that separates the two, so that is what
  # is asserted — the same shape email_registration_test.rb uses for
  # default_asset. Ownership is the property; the filename is a proxy for it.
  test "this app's own background is what ships" do
    entry = Studio::EmailCatalog.entry("magic_link")

    assert entry.layered?, "a host that registers a background is asking to layer"

    path = Rails.root.join("app/assets/images", entry.background)
    assert path.exist?,
      "#{entry.background} is registered but this app does not own it — it is " \
      "resolving from studio-engine, so the sign-in email ships the ENGINE's " \
      "artwork. Add the file to app/assets/images or register the app's own."
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
