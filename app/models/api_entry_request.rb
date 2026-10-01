# One agent-API request to create an entry, remembered by its Idempotency-Key
# (docs/AGENT_API.md, "Retrying safely"). Entries::ApiSubmission owns every
# transition; this class holds the states and the two clocks they are read by.
#
# WHY IT EXISTS. An entry spends an on-chain token, which cannot be undone, and
# the caller is software that retries. The row is what lets a retry find the
# first request's outcome instead of spending a second time.
#
# THE STATES.
#
#   executing   A request holding this key is running now. A second request
#               with the key is told to wait (409 idempotency_in_progress).
#               A row still `executing` after IN_FLIGHT_TIMEOUT belongs to a
#               process that died; it is read as `uncertain`.
#   failed      The last attempt ended and spent nothing, with certainty. A
#               retry runs the request again from the top.
#   uncertain   The last attempt reached the chain call and we could not tell
#               whether it landed (a timeout, a dropped connection). A retry
#               looks for the paid entry on chain first, and will not spend
#               again until SETTLE_WINDOW has passed with nothing found.
#   confirming  Paid: the entry row exists and carries its payment. It is not
#               `active` yet because the confirming write failed. A retry
#               finishes it; so does Entries::OnchainReconcileJob.
#   succeeded   Done. The stored response is replayed for every later request.
#
# THE TWO CLOCKS.
#
#   IN_FLIGHT_TIMEOUT  how long a running request is given before its row is
#                      treated as abandoned. Longer than the slowest honest
#                      request: a slot probe, an account bootstrap and a
#                      30-second confirmation wait.
#   SETTLE_WINDOW      how long after a possibly-sent transaction it could
#                      still land. Entries are signed against a fresh blockhash
#                      (never a durable nonce), which the cluster stops
#                      accepting after about 150 slots, roughly 60 to 90
#                      seconds. Past the window a transaction that has not
#                      landed never will, so spending again is safe.
class ApiEntryRequest < ApplicationRecord
  STATES = %w[executing failed uncertain confirming succeeded].freeze
  IN_FLIGHT_TIMEOUT = 120.seconds
  SETTLE_WINDOW = 150.seconds

  # Printable ASCII, no spaces: a UUID, a hash, anything a client would mint.
  KEY_FORMAT = /\A[\x21-\x7E]{1,255}\z/

  belongs_to :user
  belongs_to :contest
  belongs_to :api_key, optional: true
  belongs_to :entry, optional: true

  validates :idempotency_key, presence: true, format: { with: KEY_FORMAT }
  validates :fingerprint, :attempted_at, presence: true
  validates :state, inclusion: { in: STATES }

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end

  # What was asked for, reduced to one string. Pick ORDER is not part of it:
  # the same six teams are the same lineup.
  def self.fingerprint(contest:, matchup_ids:, allow_usdc:)
    Digest::SHA256.hexdigest(JSON.generate([contest.slug, matchup_ids.map(&:to_i).sort, allow_usdc ? true : false]))
  end

  # A live request holds this key right now.
  def in_flight?(now = Time.current)
    executing? && attempted_at > now - IN_FLIGHT_TIMEOUT
  end

  # The moment after which no transaction from this request can still have been
  # SENT, or nil when the request cannot have a spend outstanding. An abandoned
  # `executing` row could have broadcast at any point while it ran.
  def uncertain_since(now = Time.current)
    return spend_uncertain_at || updated_at if uncertain?
    return attempted_at + IN_FLIGHT_TIMEOUT if executing? && !in_flight?(now)

    nil
  end

  # Whether a spend from this request could still be outstanding on chain.
  def unsettled?(now = Time.current)
    !uncertain_since(now).nil?
  end

  def settles_at(now = Time.current)
    uncertain_since(now)&.+(SETTLE_WINDOW)
  end

  def inspect
    "#<ApiEntryRequest id=#{id.inspect} user_id=#{user_id.inspect} state=#{state.inspect}>"
  end
end
