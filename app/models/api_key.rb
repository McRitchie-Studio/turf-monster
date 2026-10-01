# An agent API key: the credential that lets an LLM agent act for ONE player
# without a browser cookie (docs/AGENT_API.md).
#
# THE RAW KEY IS NEVER STORED. `mint!` generates it, keeps only its SHA-256
# digest and a short display prefix, and hands the raw value back exactly once
# on the returned record's `raw_token` reader — an in-memory attribute that is
# gone as soon as that object is. Nothing can recover a key afterwards; a player
# who loses one revokes it and mints another.
#
# WHY A BARE SHA-256 AND NOT BCRYPT. A password needs a slow hash because it is
# guessable. This is 40 characters from a 62-symbol alphabet (~238 bits) drawn
# from SecureRandom, so there is nothing to brute force, and a fast digest is
# what lets a request be authenticated with one indexed lookup.
#
# THE ELIGIBILITY STAMP. API requests come from an agent's servers, so their IP
# says nothing about where the player is. Eligibility (geo, and the age gate
# when that flag is on) is therefore checked ONCE, at mint, against the player's
# own browser request, and recorded here. A key that exists is a key whose
# owner was eligible when they minted it; it expires after LIFETIME so that
# claim is re-proved at least that often.
class ApiKey < ApplicationRecord
  TOKEN_PREFIX  = "tmk_".freeze
  TOKEN_LENGTH  = 40
  TOKEN_FORMAT  = /\A#{TOKEN_PREFIX}[A-Za-z0-9]{#{TOKEN_LENGTH}}\z/
  PREFIX_LENGTH = TOKEN_PREFIX.length + 6
  LIFETIME      = 90.days
  MAX_ACTIVE_PER_USER = 5
  NAME_MAX_LENGTH = 40
  # last_used_at is a "roughly when" for the account page, not an audit log:
  # writing it on every request would turn each API read into a row write.
  LAST_USED_RESOLUTION = 1.minute

  GEO_RESULTS = %w[allowed].freeze
  AGE_RESULTS = %w[passed not_required].freeze

  class LimitReached < StandardError; end

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validates :prefix, :expires_at, :eligibility_attested_at, presence: true
  # Required: the name is how a player tells "the key I gave Claude" from "the
  # key in that script" when one of them has to be revoked.
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :eligibility_geo_result, inclusion: { in: GEO_RESULTS }
  validates :eligibility_age_result, inclusion: { in: AGE_RESULTS }

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # The raw key, present ONLY on the instance `mint!` returns.
  attr_reader :raw_token

  # Never let the raw key or its digest ride along in an #inspect that ends up
  # in a log line or an error report.
  def inspect
    "#<ApiKey id=#{id.inspect} user_id=#{user_id.inspect} prefix=#{prefix.inspect}>"
  end

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  # Mint a key for `user`, stamped with the eligibility the CALLER has already
  # established from the player's browser request. This method does not decide
  # eligibility — it has no request to read — it only refuses to record a
  # verdict outside the known vocabulary (the validations above).
  #
  # The per-user cap is checked under a row lock on the user so two concurrent
  # mints cannot both pass a count of four.
  def self.mint!(user:, name:, geo_country:, geo_state:, age_result:, now: Time.current)
    raw = TOKEN_PREFIX + SecureRandom.alphanumeric(TOKEN_LENGTH)

    transaction do
      user.lock!
      raise LimitReached, "You can have up to #{MAX_ACTIVE_PER_USER} active keys. Revoke one first." if
        user.api_keys.active.count >= MAX_ACTIVE_PER_USER

      key = create!(
        user: user,
        name: name.to_s.strip.presence,
        token_digest: digest(raw),
        prefix: raw[0, PREFIX_LENGTH],
        expires_at: now + LIFETIME,
        eligibility_geo_country: geo_country.presence,
        eligibility_geo_state: geo_state.presence,
        eligibility_geo_result: "allowed",
        eligibility_age_result: age_result.to_s,
        eligibility_attested_at: now
      )
      key.instance_variable_set(:@raw_token, raw)
      key
    end
  end

  # The key a raw bearer value belongs to, whatever its state — the caller
  # decides what a revoked or expired key means. A value that is not even
  # key-shaped never reaches the database.
  def self.find_by_raw_token(raw_token)
    raw = raw_token.to_s
    return nil unless raw.match?(TOKEN_FORMAT)

    find_by(token_digest: digest(raw))
  end

  def revoked?
    revoked_at.present?
  end

  def expired?(now = Time.current)
    expires_at <= now
  end

  def active?(now = Time.current)
    !revoked? && !expired?(now)
  end

  def status(now = Time.current)
    return "revoked" if revoked?
    return "expired" if expired?(now)

    "active"
  end

  # Idempotent: revoking twice keeps the first timestamp.
  def revoke!(now: Time.current)
    return self if revoked?

    update!(revoked_at: now)
    self
  end

  def touch_last_used!(now: Time.current)
    return if last_used_at && last_used_at > now - LAST_USED_RESOLUTION

    update_column(:last_used_at, now)
  end

  # The attestation as the API reports it (GET /api/v1/me).
  def eligibility
    {
      geo: {
        result: eligibility_geo_result,
        country: eligibility_geo_country,
        state: eligibility_geo_state
      },
      age_gate: eligibility_age_result,
      attested_at: eligibility_attested_at&.iso8601
    }
  end
end
