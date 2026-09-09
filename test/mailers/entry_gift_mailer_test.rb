require "test_helper"

# EntryGiftMailer — the note a friend gets before they have an account.
class EntryGiftMailerTest < ActionMailer::TestCase
  setup do
    @sender = users(:alex)
    @gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @sender,
                              contest: contests(:one),
                              note: "Put a lineup in this week.")
    @mail = EntryGiftMailer.gift_invite(@gift, "tok_abc123")
  end

  test "addresses the recipient and speaks in the sender's name" do
    assert_equal ["friend@example.com"], @mail.to
    assert_match @sender.name, @mail.subject
    assert_match "free entry", @mail.subject
  end

  # A reply must reach the PERSON who invited them, not team@. Somebody
  # answering "wait, what is this?" is answering a friend.
  test "replies go to the sender" do
    assert_equal [@sender.email], @mail.reply_to
  end

  test "carries the claim link in both parts" do
    assert_match "/l/tok_abc123", @mail.html_part.body.to_s
    assert_match "/l/tok_abc123", @mail.text_part.body.to_s
  end

  test "quotes the personal note in both parts" do
    assert_match "Put a lineup in this week.", @mail.html_part.body.to_s
    assert_match "Put a lineup in this week.", @mail.text_part.body.to_s
  end

  test "names the contest it lands on" do
    assert_match contests(:one).name, @mail.html_part.body.to_s
  end

  # The no-note case renders, and renders no EMPTY quote block.
  #
  # The assertion here was `assert_no_match(/&ldquo;\s*&rdquo;/, ...)` and it was
  # VACUOUS: those entities live in _gift_row.html.erb, never in this template,
  # so no input could have made it fail. The quote marks this view actually draws
  # are the CSS border on the note's table row, so the honest assertion is that
  # the note block itself is absent.
  test "renders without a note, and draws no empty note block" do
    gift = EntryGift.create!(recipient_email: "other@example.com", sender: @sender)
    mail = EntryGiftMailer.gift_invite(gift, "tok_xyz")
    html = mail.html_part.body.to_s

    assert_match "/l/tok_xyz", html
    assert_no_match(/border-left:3px solid/, html, "the note's quote block must not render")
    # And the control: with a note, that block IS drawn — without this the
    # assertion above passes for a template that lost the block entirely.
    with_note = EntryGiftMailer.gift_invite(
      EntryGift.create!(recipient_email: "third@example.com", sender: @sender, note: "hi"),
      "tok_2"
    )
    assert_match(/border-left:3px solid/, with_note.html_part.body.to_s)
  end

  # ESCAPING — this feature's most attacker-adjacent surface, and nothing pinned
  # it. The note and the sender name are the only free text in the email, both
  # are operator-supplied, and both are interpolated into HTML. ERB escapes them
  # by default; the danger is a future `.html_safe` or `raw` added for styling.
  test "a script tag in the note is escaped in HTML and literal in text" do
    gift = EntryGift.create!(recipient_email: "xss@example.com", sender: @sender,
                             note: "<script>alert(1)</script>")
    mail = EntryGiftMailer.gift_invite(gift, "tok_xss")
    html = mail.html_part.body.to_s

    assert_match "&lt;script&gt;", html, "the note must be escaped"
    assert_no_match(/<script>alert\(1\)<\/script>/, html, "no live script tag may reach the inbox")
    # The text part is not HTML, so the literal is correct there — and asserting
    # it keeps someone from "fixing" the text part by escaping it too.
    assert_match "<script>alert(1)</script>", mail.text_part.body.to_s
  end

  test "a script tag in the sender's name is escaped too" do
    attacker = User.create!(email: "attacker@example.com", name: "<script>alert(2)</script>")
    gift = EntryGift.create!(recipient_email: "xss2@example.com", sender: attacker)
    mail = EntryGiftMailer.gift_invite(gift, "tok_xss2")

    assert_match "&lt;script&gt;", mail.html_part.body.to_s
    assert_no_match(/<script>alert\(2\)<\/script>/, mail.html_part.body.to_s)
  end

  # display_name falls back to the email local part, so an account with no
  # handle would introduce itself as a fragment of an address. The mailer must
  # not use it.
  test "a nameless sender is 'A friend', never an email fragment" do
    nameless = User.create!(email: "quiet-sender@example.com")
    nameless.update_columns(name: nil, username: nil)
    gift = EntryGift.create!(recipient_email: "friend2@example.com", sender: nameless.reload)
    mail = EntryGiftMailer.gift_invite(gift, "tok_1")

    assert_match "A friend", mail.subject
    assert_no_match(/quiet-sender/i, mail.subject)
  end

  test "states the address the link is bound to" do
    assert_match "friend@example.com", @mail.html_part.body.to_s
  end
end
