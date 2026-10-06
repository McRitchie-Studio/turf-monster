class Message < ApplicationRecord
  BODY_MAX_LENGTH = 500

  belongs_to :contest
  belongs_to :user
  # Ordered so grouped reaction pills render oldest-first (stable left-to-right
  # order as new emoji are added). delete_all (not :destroy) clears rows by FK
  # in one statement when a message is hard-deleted — no per-reaction broadcast
  # is wanted once the whole bubble is gone, and it sidesteps the stale in-memory
  # collection cache that can leave :destroy iterating an empty target.
  has_many :reactions, -> { order(:created_at, :id) }, dependent: :delete_all

  before_validation { self.body = body.strip if body.is_a?(String) }

  validates :body, presence: true, length: { maximum: BODY_MAX_LENGTH }
  # OPSEC-048: a frozen account cannot post in a contest chat.
  include FrozenAccount::Validation
  validates_account_not_frozen :user, on: :create

  # hidden_at nil = visible. Admin soft-delete sets it (see #hide!).
  scope :visible, -> { where(hidden_at: nil) }

  # System/announcement lines (join announcements, etc.) vs typed user messages.
  scope :system_messages, -> { where(system: true) }

  # Post the "joined the contest" announcement for `user` in `contest` — once.
  # Authored BY the joining user (so the row has a real author + the dedupe
  # query is a clean user/contest scope) but flagged `system: true` so the chat
  # renders it as a centered, avatar-less announcement, not a typed bubble.
  #
  # Idempotent + non-fatal by design: it runs inside the entry-confirm path,
  # and neither a chat-disabled contest, an already-announced user, nor a
  # broadcast/DB hiccup may fail the entry that already confirmed. Returns the
  # Message on a fresh announcement, nil when skipped.
  def self.announce_join!(contest:, user:)
    return nil unless contest&.chat_enabled?
    return nil unless user
    return nil if join_announced?(contest: contest, user: user)

    create!(
      contest: contest,
      user: user,
      system: true,
      body: "🎉 #{user.display_name} joined the contest"
    )
  rescue ActiveRecord::RecordNotUnique
    # Lost a concurrent race (two confirms in flight) — the other write won.
    nil
  rescue => e
    ErrorLog.capture!(e)
    nil
  end

  # Has this user already had a join announcement posted in this contest?
  # Counts hidden rows too — an admin hiding the announcement must not let a
  # re-confirm repost it.
  def self.join_announced?(contest:, user:)
    system_messages.where(contest_id: contest.id, user_id: user.id).exists?
  end

  # Real-time delivery (ActionCable + Turbo Streams). New messages prepend to
  # the panel; an admin hide removes the bubble for everyone. The partial is
  # rendered viewer-agnostically — see app/views/messages/_message.html.erb.
  after_create_commit :broadcast_new_message
  after_update_commit :broadcast_removal, if: -> { saved_change_to_hidden_at? && hidden? }

  # Last `limit` visible messages for a contest, newest-first — the chat panel
  # reads top to bottom with the freshest message on top.
  def self.recent_for(contest, limit: 50)
    visible.where(contest: contest)
           .includes(user: { avatar_attachment: :blob }, reactions: :user)
           .order(created_at: :desc, id: :desc)
           .limit(limit)
           .to_a
  end

  def hidden?
    hidden_at.present?
  end

  # Admin soft-delete: keeps the row for audit, hides it from the live UI.
  def hide!(admin)
    update!(hidden_at: Time.current, hidden_by_id: admin&.id)
  end

  private

  # Broadcasts are best-effort — a cable/Redis hiccup must not fail the request
  # that already saved (and committed) the message.
  def broadcast_new_message
    broadcast_prepend_to(
      [contest, :messages],
      target: "contest_#{contest_id}_messages",
      partial: "messages/message",
      locals: { message: self }
    )
  rescue => e
    ErrorLog.capture!(e)
  end

  def broadcast_removal
    broadcast_remove_to([contest, :messages], target: "message_#{id}")
  rescue => e
    ErrorLog.capture!(e)
  end

  public

  # Push this message's reactions row to everyone in the room. Called from
  # Reaction's after-commit hooks. Uses the custom "reactions" Turbo Stream
  # action (registered in contests/_chat_panel) — instead of a plain `replace`
  # — so the client RECONCILES the new pills against the existing row and can
  # animate each pill (pop on add, bump on increment, shrink on removal) rather
  # than swapping the whole row with no transition. Best-effort — see above.
  def broadcast_reactions
    broadcast_action_to(
      [contest, :messages],
      action: "reactions",
      target: "message_#{id}_reactions",
      partial: "messages/reactions",
      locals: { message: self }
    )
  rescue => e
    ErrorLog.capture!(e)
  end
end
