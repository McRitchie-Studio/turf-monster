# frozen_string_literal: true

module Solana
  # A wallet failure that happened ENTIRELY in the browser, sanitised into the
  # one sentence that gets persisted.
  #
  # WHY THIS EXISTS. `window.solanaConnectAndVerify` and the three modals that
  # call it handle their own rejections: the throw is caught, run through
  # `parseSolanaError`, and painted into an `x-text` paragraph. Nothing reached
  # the server, so nothing reached `error_logs` — the backend discipline's first
  # principle (every workflow rescues into an ErrorLog) had no client-side
  # counterpart and this whole surface was dark. On 2026-09-06 a user whose
  # Phantom held no keypair was told to check their USDC balance seven times in
  # one production session before an operator noticed by hand.
  #
  # THE RAW MESSAGE IS THE POINT. `mapped_message` is what the user read;
  # `raw_message` is what the wallet actually said. Only the pair makes a
  # MIS-mapping diagnosable — the 2026-09-06 incident was precisely a correct
  # pipeline mapping a wallet string it had never met onto balance advice, and
  # with only the mapped half in hand there is nothing to notice.
  #
  # ── THE PII RULE, and it is the HOUSE rule, not a new one ────────────────────
  #
  # app/javascript/debug_logger.js already settled this vocabulary for this exact
  # domain, and this class does not get to answer it differently:
  #
  #   CREDENTIAL — a copy of the value can be USED by whoever reads it:
  #     the SIWS `signature`, the SIWS `message` (it carries the nonce), the
  #     `nonce` itself, magic-link tokens, secrets, private keys. NEVER STORED.
  #   PUBLIC — the identifier that makes the row worth having:
  #     the wallet `pubkey` (already rendered on <body data-wallet-address>), an
  #     on-chain `tx_signature`, our own user id. KEPT, DELIBERATELY. Over-
  #     redaction blinds the tool it is protecting; a log that hides the pubkey
  #     cannot debug a wallet.
  #
  # Two layers enforce it, because one is not enough and each covers the other's
  # blind spot:
  #
  #   1. BY KEY. SolanaSessionsController#client_failure_params permits exactly
  #      four keys, and `.from_params` below reads exactly those four BY NAME.
  #      Read the pair, not either half: measured 2026-09-07, widening the permit
  #      list alone changed nothing, because the reader never looks at the rest of
  #      the hash. The READER is what makes a credential unstorable; the permit
  #      list is what keeps it out of the params object at all. They are asserted
  #      as ONE set in test/controllers/wallet_failure_reporter_wiring_test.rb, so
  #      neither can drift from the other. (Same instinct as debug_logger.js —
  #      "the key names are the thing this app actually controls" — but the
  #      enforcement point is the read, not the permit.)
  #
  #   2. BY VALUE, here. `raw_message` is free text composed by a WALLET, so key
  #      allowlisting says nothing about what is inside it — and this app hands
  #      the wallet a string containing its own nonce to sign:
  #
  #        message = domain + ' wants you to sign in with your Solana account:\n'
  #                + pubkeyB58 + '\n\n' + userIdLine + 'Sign in to Turf Monster'
  #                + '\n\nNonce: ' + data.nonce
  #          (app/views/layouts/application.html.erb, the non-signIn fallback)
  #
  #      A wallet that quotes back the message it refused to sign therefore hands
  #      us the live nonce inside a field the key allowlist has already approved.
  #      That is not a hypothetical: it is the SAME gap debug_logger.js names in
  #      its own comment — "a body that is not JSON is never PARSED, so it is
  #      never REDACTED" — one level down, at values instead of bodies.
  #
  # SCRUB LEAVES A HOLE FOR THE PUBKEY ON PURPOSE. A 32-byte ed25519 pubkey is at
  # most 44 base58 characters; a 64-byte signature is 87-88. The signature rule
  # therefore starts at 64, so a pubkey passes through it untouched and a
  # signature cannot.
  class ClientFailureReport
    # The places a wallet rejection is caught. THREE are render surfaces; two of
    # those three are in the solana-studio GEM and are not wired yet (see
    # docs/AUTH.md, "Reporting client-side wallet failures") — they are listed
    # here because the stage is the operator's filter and the list is what makes
    # an unwired site visible as a MISSING stage rather than as no failures.
    #
    # THE LAST TWO ARE NOT SURFACES, and that is the point of them. Both are
    # guards inside the connect + signMessage fallback in solanaConnectAndVerify
    # (app/views/layouts/application.html.erb) — the two places that REPLACE a
    # wallet's message with a sentence of our own before rethrowing. Each reports
    # from in there because that is the last moment the wallet's own words exist;
    # a report from any surface downstream carries our sentence in BOTH halves
    # and is undiagnosable.
    #
    # They are SEPARATE stages because they are separate diagnoses, and an
    # operator answers them differently:
    #
    #   connect_verify_fallback  — connect() never answered. The wallet is
    #                              installed but holds no keypair. The user is
    #                              told to create or import one.
    #   connect_verify_signature — connect() ANSWERED with a publicKey and
    #                              signMessage then refused. A keypair exists;
    #                              telling this user to create one is false. The
    #                              user is told signing moves no funds, try again.
    #
    # On both, `raw_message` is what the wallet said and `mapped_message` is what
    # the user read, so the pair stays diagnosable on either path.
    STAGES = %w[
      wallet_setup_connect
      wallet_connect
      web3_step_up
      connect_verify_fallback
      connect_verify_signature
    ].freeze

    # A stage or brand off the list is recorded as this rather than refused. A
    # report we cannot label is still a report; dropping it would put the surface
    # back in the dark for exactly the call site nobody remembered to register.
    UNKNOWN = "unknown"

    # Long enough for a wallet sentence plus an RPC preamble, short enough that a
    # scripted flood cannot use error_logs as free storage.
    MAX_MESSAGE = 500

    REDACTED = "[redacted]"

    # `Nonce: <value>` — the labelled form the SIWS message writes. Anchored on
    # the SEPARATOR, not on the word: `/nonce\s*\S+/` also eats the next word of
    # "wallet omitted the nonce and died", which is a sentence we want to keep.
    NONCE_RE = /\bnonce\b\s*[:=]\s*\S+/i

    # Bitcoin base58 (no 0, O, I, l), 64+ characters — an ed25519 signature.
    SIGNATURE_RE = /[1-9A-HJ-NP-Za-km-z]{64,}/

    # 32+ hex characters. `session[:solana_nonce] = SecureRandom.hex(16)` is
    # EXACTLY 32, so this is the unlabelled form of the rule above. Base58 cannot
    # cover it: hex uses `0`, which base58 does not have.
    HEX_SECRET_RE = /\b\h{32,}\b/

    attr_reader :provider, :stage, :raw_message, :mapped_message

    def self.from_params(permitted)
      new(
        provider: permitted[:provider],
        stage: permitted[:stage],
        raw_message: permitted[:raw_message],
        mapped_message: permitted[:mapped_message]
      )
    end

    def initialize(provider:, stage:, raw_message:, mapped_message:)
      # Through the SAME registry that gates the persisted `web3_wallet_provider`
      # column, so a brand cannot be spelled two ways across the two tables.
      @provider       = Solana::WalletProvider.normalize(provider).presence || UNKNOWN
      @stage          = STAGES.include?(stage.to_s) ? stage.to_s : UNKNOWN
      @raw_message    = self.class.scrub(raw_message)
      @mapped_message = self.class.scrub(mapped_message)
    end

    # The single line that becomes ErrorLog#message. Ordered so the two facts an
    # operator triages on — which surface, which brand — read first, and the two
    # message halves read as a pair.
    def summary
      "[client-wallet] stage=#{stage} provider=#{provider} " \
      "shown=#{quoted(mapped_message)} raw=#{quoted(raw_message)}"
    end

    # Layer 2 of the PII rule (see the class comment).
    def self.scrub(text)
      # Solana::Config.redact_message FIRST, and it does two jobs here:
      #   * `.scrub("?")` — a client can POST invalid UTF-8, and `gsub` on an
      #     invalid string raises ArgumentError. Every rule below runs on the
      #     result, so this is what keeps them from blowing up on hostile input.
      #   * it masks any RPC endpoint and its api-key buried in the sentence.
      #     A wallet error can quote an RPC response, and the credentialed
      #     Helius URL is a secret this app already knows how to lose that way
      #     (OPSEC — see Solana::ClientLogger, which redacts for the same reason).
      out = Solana::Config.redact_message(text)
      out = out.gsub(NONCE_RE, "nonce: #{REDACTED}")
      out = out.gsub(SIGNATURE_RE, REDACTED)
      out = out.gsub(HEX_SECRET_RE, REDACTED)
      out.truncate(MAX_MESSAGE)
    end

    private

    def quoted(value)
      value.presence || "(none)"
    end
  end
end
