# Re-seals every managed-wallet secret (users.encrypted_web2_solana_private_key)
# under the CURRENT MANAGED_WALLET_ENCRYPTION_KEY, and counts the rows that
# prove it. Drives `bin/rails solana:reencrypt_managed_wallets` (the migration)
# and `bin/rails solana:verify_managed_wallet_keys` (read-only).
#
# WHY THIS EXISTS (managed-wallet-key-rotation). The migration it replaces
# decided a row was done by its "v2:" prefix. The prefix names the SCHEME, not
# the key, so after a key change every row still looked done: the task skipped
# them all, printed "0 migrated, N already v2, 0 failed" and exited 0 while
# every managed wallet had become undecryptable. Nothing here trusts a label.
# A row is "already new" only when the current key ALONE opens it and the
# secret inside derives the wallet address stored beside it.
#
# THE RULES, per row, in order:
#   1. Current key alone opens it, and it derives the stored address -> already-new.
#   2. Otherwise open it with the OLD key (MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS,
#      or the pre-OPSEC-015 legacy scheme for an untagged row). It must derive
#      the stored address, or the row is reported and left alone.
#   3. Dry run stops here: the row is counted as would-migrate. Nothing written.
#   4. Re-seal the EXACT plaintext under the current key, then open the new
#      ciphertext with the current key ALONE and compare it to the original
#      plaintext in memory. Any mismatch: reported, row left on the old key.
#   5. Write with compare-and-swap (only if the row still holds the ciphertext
#      read in step 1), so a row that changed underneath is never clobbered.
#
# Every row is its own atomic write, so a run that dies halfway leaves each row
# either fully old or fully new -- and both keys still open both. Re-running
# classifies the new ones as already-new by step 1 and finishes the rest.
#
# SECRETS. Nothing here prints, logs or records a key or a plaintext. Output
# and ErrorLog rows carry a user id, the PUBLIC wallet address, a fixed reason
# and at most an exception CLASS name -- never an exception message, because a
# library message is not ours to vouch for.
module Solana
  class ManagedWalletRotation
    # Raised before anything is read or written, when the configuration makes
    # a rotation unsafe to start. The message names the rule, never the value.
    Refused = Class.new(StandardError)

    # Carried into ErrorLog for one row that was not migrated. Never raised.
    RowFailed = Class.new(StandardError)

    KEY_ENV      = Solana::Keypair::KEY_ENV
    PREVIOUS_ENV = Solana::Keypair::PREVIOUS_KEY_ENV

    # A NEW key must look like what the rotation SOP mints: SecureRandom.hex(32),
    # 64 hex characters (32 bytes). Anything else -- a trailing newline from a
    # paste, a truncated copy, a passphrase -- is refused rather than adopted.
    # The PREVIOUS key is deliberately NOT format-checked: it is whatever the
    # app has been using, and the only proof it is right is that rows open
    # under it (which the dry run shows) -- not what it looks like.
    NEW_KEY_FORMAT = /\A\h{64}\z/

    RunResult = Struct.new(:dry_run, :total, :migrated, :already_new, :failed,
                           :from_previous, :from_legacy, :check, keyword_init: true) do
      # The migration is complete only when no row failed, every walked row is
      # accounted for as migrated or already-new, and an independent recount
      # finds every row readable under the current key alone. A dry run is
      # "clean" when no row failed -- it wrote nothing, so there is no recount.
      def complete?
        return failed.zero? if dry_run

        failed.zero? && (migrated + already_new == total) && check&.verified?
      end
    end

    CheckResult = Struct.new(:total, :current, :previous, :legacy, :wrong_wallet, :unreadable,
                             keyword_init: true) do
      def verified? = current == total
    end

    # :rotation when a previous key is configured (a real key change), or
    # :legacy_only when it is not (the OPSEC-015 legacy->v2 migration, which
    # must still find every v2 row readable under the current key). Raises
    # Refused for every configuration that could not end well.
    def self.preflight!(env = ENV)
      if env.key?(PREVIOUS_ENV) && env[PREVIOUS_ENV].to_s.strip.empty?
        raise Refused, "#{PREVIOUS_ENV} is set but empty. That is what an empty $OLD writes. " \
                       "Set it to the retiring key, or unset it entirely."
      end
      return :legacy_only unless env.key?(PREVIOUS_ENV)

      current = env[KEY_ENV].to_s
      previous = env[PREVIOUS_ENV].to_s
      if current.strip.empty?
        raise Refused, "#{KEY_ENV} (the NEW key) is absent. A rotation re-seals every row under it; " \
                       "there is nothing to re-seal under."
      end
      unless current.match?(NEW_KEY_FORMAT)
        raise Refused, "#{KEY_ENV} (the NEW key) is malformed: #{malformation(current)}. " \
                       "Mint it with SecureRandom.hex(32) -- 64 hex characters."
      end
      if current == previous || current.strip.casecmp?(previous.strip)
        raise Refused, "#{KEY_ENV} equals #{PREVIOUS_ENV}. Rotating a key onto itself changes nothing " \
                       "and would report success."
      end

      :rotation
    end

    # Which rule a NEW key breaks. Describes the shape, never the value.
    def self.malformation(value)
      return "it has leading or trailing whitespace" if value != value.strip
      return "it contains characters that are not hexadecimal" unless value.match?(/\A\h*\z/)

      "it is not 64 characters long"
    end
    private_class_method :malformation

    # Every managed-wallet row. `unscoped` on purpose: a default scope added to
    # User later must never hide a row from the walk -- a row the migration
    # never sees is a wallet that dies when the old key is retired.
    def self.scope
      User.unscoped.where.not(encrypted_web2_solana_private_key: [nil, ""])
    end

    # Read-only census: how many rows open under the current key ALONE and
    # derive their stored address. Writes nothing, logs nothing.
    def self.check(out: nil)
      Solana::Keypair.reset_encryptors!
      counts = Hash.new(0)
      scope.find_each do |user|
        counts[:total] += 1
        counts[classify_for_check(user)] += 1
      end
      result = CheckResult.new(total: counts[:total], current: counts[:current], previous: counts[:previous],
                               legacy: counts[:legacy], wrong_wallet: counts[:wrong_wallet],
                               unreadable: counts[:unreadable])
      print_check(result, out) if out
      result
    end

    def self.classify_for_check(user)
      ciphertext = user.encrypted_web2_solana_private_key
      address = user.web2_solana_address.presence
      plaintext = Solana::Keypair.open_plaintext(ciphertext, keys: [:current])
      if plaintext
        derived = address_of(plaintext)
        return derived && derived == address ? :current : :wrong_wallet
      end
      return :previous if Solana::Keypair.open_plaintext(ciphertext, keys: [:previous])
      return :legacy if Solana::Keypair.open_plaintext(ciphertext, keys: [:legacy])

      :unreadable
    rescue StandardError
      :unreadable
    end
    private_class_method :classify_for_check

    def self.print_check(r, out)
      out.puts "Managed-wallet key check (read-only): #{r.total} row(s)"
      out.puts "  total: #{r.total}  current-key: #{r.current}  still-previous-key: #{r.previous}  " \
               "legacy-scheme: #{r.legacy}  wrong-wallet: #{r.wrong_wallet}  unreadable: #{r.unreadable}"
      if r.verified?
        out.puts "VERIFIED -- #{r.current} of #{r.total} row(s) open under the current key alone."
      else
        out.puts "NOT VERIFIED -- #{r.total - r.current} of #{r.total} row(s) do not open under the current key alone. " \
                 "Do NOT retire the previous key."
      end
    end
    private_class_method :print_check

    # The Base58 wallet address a stored plaintext derives, or nil when the
    # plaintext is not a usable Solana secret.
    def self.address_of(plaintext)
      return nil unless plaintext.is_a?(String)

      Solana::Keypair.from_bytes(Base64.strict_decode64(plaintext)).to_base58
    rescue StandardError
      nil
    end

    attr_reader :mode, :dry_run

    def initialize(dry_run: false, out: $stdout)
      @mode = self.class.preflight!
      @dry_run = dry_run
      @out = out
    end

    def run
      Solana::Keypair.reset_encryptors!
      @counts = Hash.new(0)
      print_header
      self.class.scope.find_each do |user|
        @counts[:total] += 1
        record(process(user))
      end
      result = build_result
      print_summary(result)
      result
    end

    private

    attr_reader :out

    # The keys the OLD ciphertext may be opened with. Rotation accepts the
    # previous key and (for a stray pre-OPSEC-015 row) the legacy scheme; the
    # legacy-only run accepts only the legacy scheme, so a v2 row the current
    # key cannot open is a FAILURE there -- never "already v2".
    def source_keys
      mode == :rotation ? %i[previous legacy] : %i[legacy]
    end

    def process(user)
      ciphertext = user.encrypted_web2_solana_private_key
      address = user.web2_solana_address
      return failure(user, "no web2_solana_address to verify the secret against") if address.blank?

      # 1. Already under the current key? Asked of the current key ALONE.
      if (plaintext = Solana::Keypair.open_plaintext(ciphertext, keys: [:current]))
        return :already_new if self.class.address_of(plaintext) == address

        return failure(user, "opens under the current key but does not derive its stored wallet address")
      end

      # 2. Open with the old key.
      source, plaintext = open_with_old_key(ciphertext)
      return failure(user, no_key_reason(ciphertext)) if plaintext.nil?
      unless self.class.address_of(plaintext) == address
        return failure(user, "opens under the #{source} key but does not derive its stored wallet address")
      end

      # 3. Dry run: counted, never written.
      return [:would_migrate, source] if dry_run

      # 4. Re-seal the exact plaintext; read it back under the current key ALONE.
      fresh = Solana::Keypair.seal_plaintext(plaintext)
      reread = Solana::Keypair.open_plaintext(fresh, keys: [:current])
      unless reread.is_a?(String) &&
             ActiveSupport::SecurityUtils.secure_compare(reread, plaintext) &&
             self.class.address_of(reread) == address
        return failure(user, "read-back under the current key alone did not match; left on the #{source} key")
      end

      # 5. Compare-and-swap: write only if the row still holds what we read.
      swapped = User.unscoped.where(id: user.id, encrypted_web2_solana_private_key: ciphertext)
                    .update_all(encrypted_web2_solana_private_key: fresh)
      return failure(user, "row changed during the migration; left as found -- re-run to pick it up") unless swapped == 1

      [:migrated, source]
    rescue StandardError => e
      failure(user, "unexpected #{e.class}; left as found")
    end

    def open_with_old_key(ciphertext)
      source_keys.each do |name|
        plaintext = Solana::Keypair.open_plaintext(ciphertext, keys: [name])
        return [name, plaintext] if plaintext
      end
      [nil, nil]
    end

    def no_key_reason(ciphertext)
      if Solana::Keypair.current_version?(ciphertext) && mode == :legacy_only
        "v2 row opens under no configured key -- if #{KEY_ENV} was just changed, the old value belongs in " \
          "#{PREVIOUS_ENV} and must NOT be retired"
      else
        "opens under no configured key"
      end
    end

    def record(outcome)
      kind, source = Array(outcome)
      @counts[kind] += 1
      @counts[:"from_#{source}"] += 1 if source
    end

    def failure(user, reason)
      out.puts "  FAILED user ##{user.id} (#{user.web2_solana_address.presence || 'no address'}): #{reason}"
      log_failure(user, reason) unless dry_run
      :failed
    end

    # The durable trace (backend discipline: every write path's failure lands
    # in ErrorLog against its record). The message is built here from a fixed
    # reason -- no key, no plaintext, no library exception message. A dry run
    # writes nothing, ErrorLog included.
    def log_failure(user, reason)
      log = ErrorLog.capture!(RowFailed.new("managed-wallet re-seal: user ##{user.id} not migrated -- #{reason}"))
      log.update!(target: user, target_name: user.slug)
    rescue StandardError => e
      out.puts "  (could not write the ErrorLog row for user ##{user.id}: #{e.class})"
    end

    def build_result
      RunResult.new(
        dry_run: dry_run,
        total: @counts[:total],
        migrated: dry_run ? @counts[:would_migrate] : @counts[:migrated],
        already_new: @counts[:already_new],
        failed: @counts[:failed],
        from_previous: @counts[:from_previous],
        from_legacy: @counts[:from_legacy],
        check: dry_run ? nil : self.class.check
      )
    end

    def print_header
      label = if mode == :rotation
        "ROTATION -- opening with #{PREVIOUS_ENV}, sealing under #{KEY_ENV}"
      else
        "LEGACY-ONLY -- no #{PREVIOUS_ENV}; every v2 row must already open under #{KEY_ENV}"
      end
      out.puts "Managed-wallet re-seal: #{label}"
      out.puts "DRY RUN -- nothing will be written." if dry_run
      out.puts "Walking #{self.class.scope.count} managed-wallet row(s)..."
    end

    def print_summary(r)
      moved = dry_run ? "would-migrate" : "migrated"
      out.puts
      out.puts "total: #{r.total}  #{moved}: #{r.migrated}  already-new: #{r.already_new}  failed: #{r.failed}"
      out.puts "  (#{moved}: #{r.from_previous} from the previous key, #{r.from_legacy} from the legacy scheme)"
      if dry_run
        print_dry_run_verdict(r)
      else
        c = r.check
        out.puts "Read-back: #{c.current} of #{c.total} row(s) open under the current key alone."
        print_run_verdict(r)
      end
      return unless mode == :rotation && r.total.positive? && r.migrated.zero? && r.failed.zero?

      out.puts "NOTE: no row opened under the previous key. On a FIRST run that means the two keys are swapped, " \
               "or this rotation already happened -- check before retiring anything."
    end

    def print_dry_run_verdict(r)
      if r.complete?
        out.puts "DRY RUN CLEAN -- every row either opens under the current key or opened under the old key " \
                 "and derived its stored wallet address. Nothing was written."
      else
        out.puts "DRY RUN FOUND #{r.failed} ROW(S) THAT WOULD NOT MIGRATE -- see FAILED lines. Nothing was written."
      end
    end

    def print_run_verdict(r)
      if r.complete?
        out.puts "COMPLETE -- #{r.check.current} of #{r.check.total} row(s) verified under the current key alone."
      else
        keep = if mode == :rotation
          "Keep #{PREVIOUS_ENV} configured -- do NOT retire it."
        else
          "Change no key until every row verifies."
        end
        out.puts "NOT COMPLETE -- #{r.failed} row(s) failed and #{r.check.total - r.check.current} row(s) do not " \
                 "open under the current key alone. #{keep} Safe to re-run."
      end
    end
  end
end
