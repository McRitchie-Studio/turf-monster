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

  test "renders without a note" do
    gift = EntryGift.create!(recipient_email: "other@example.com", sender: @sender)
    mail = EntryGiftMailer.gift_invite(gift, "tok_xyz")
    assert_match "/l/tok_xyz", mail.html_part.body.to_s
    assert_no_match(/&ldquo;\s*&rdquo;/, mail.html_part.body.to_s)
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
