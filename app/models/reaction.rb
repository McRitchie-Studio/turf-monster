class Reaction < ApplicationRecord
  belongs_to :message
  belongs_to :user

  # === Allowed emoji ===================================================
  # Reactions are an allowlist, not free-form — the toggle endpoint validates
  # against ALLOWED so a tampered request can't write an arbitrary string into
  # the chat. Three groups:
  #   QUICK   — the themed fixed quick-bar reactions (hundred, gator, sob).
  #             Rendered by messages/_message.html.erb's hover bar — keep the
  #             two in sync.
  #   SPORTS  — the contest-derived first quick reaction (Contest#sport_emoji);
  #             listed so every sport's ball is valid even before that sport
  #             ships a contest type.
  #   PICKER  — the broader palette behind the "+" (Find another reaction).
  QUICK  = ["💯", "🐊", "😭"].freeze
  SPORTS = ["⚽", "🏈", "🏀", "⚾", "🏒", "🎾"].freeze
  PICKER = %w[👍 👎 😂 😮 🔥 💯 🎉 👏 🙏 😎 🥳 🤔 👀 ⚡ 🏆 💪 🐐 🤝 🤬 🧊 💀 ❄️].freeze
  ALLOWED = (QUICK + SPORTS + PICKER).uniq.freeze

  validates :emoji, presence: true, inclusion: { in: ALLOWED }
  validates :user_id, uniqueness: { scope: [:message_id, :emoji] }
  # OPSEC-048: a frozen account cannot react in a contest chat.
  include FrozenAccount::Validation
  validates_account_not_frozen :user, on: :create

  # A reaction change re-renders the message's reactions row for everyone in
  # the room (same Turbo Stream channel as the message itself). Best-effort:
  # a cable/Redis hiccup must not fail the toggle that already committed.
  after_create_commit  :broadcast_change
  after_destroy_commit :broadcast_change

  private

  def broadcast_change
    message.broadcast_reactions
  end
end
