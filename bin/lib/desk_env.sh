# shellcheck shell=bash
# bin/lib/desk_env.sh — the environment a turf-monster dev server starts with.
# Sourced by bin/tm and bin/parallel-server; defines TM_ENV_ALLOW and
# tm_scrub_env, and runs nothing.
#
# The environment every managed process starts with: an ALLOW-LIST.
#
# WHY (secrets-never-on-argv-or-desk-env, 2026-10-24). These processes used to
# inherit the launching shell's whole environment, and an agent's shell holds
# HEROKU_API_KEY, OP_SERVICE_ACCOUNT_TOKEN, CLAUDE_CODE_* and AGENT_API_SECRET.
# Puma and Sidekiq rename their process titles, and on macOS `pgrep -fl` and `ps`
# then print a renamed process's environment, so one `pgrep -fl` put the Heroku
# key into a transcript and it was rotated. The app reads its own secrets from
# .env (dotenv); from the parent it needs only the names below. An allow-list,
# because a deny-list misses the next name somebody exports. The hub launcher
# (mcritchie-studio bin/lib/child_env.rb) keeps the same list.
TM_ENV_ALLOW=(
  PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM TZ __CF_USER_TEXT_ENCODING
  GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_WITHOUT
  RAILS_ENV RACK_ENV RAILS_LOG_TO_STDOUT RAILS_MAX_THREADS WEB_CONCURRENCY
  PORT APP_PORT DATABASE_URL TEST_DATABASE_URL REDIS_URL PGHOST PGPORT PGUSER
  TM_PORT TM_REDIS_DB TM_SESSION_KEY TM_STRIPE_LISTENER
  LOCAL_EMAIL_CAPTURE MAIL_TRANSPORT MAILER_HOST
  AGENT_WORKTREE APP_SLUG TASK_SLUG TASK_RECORD_SLUG TASK_URL
  BINDING PAYMENT_PROVIDER
  OBJC_DISABLE_INITIALIZE_FORK_SAFETY SCREENDIR
)
# Boot flags an operator sets for one run (`ENABLE_FIAT_RAILS=true … bin/tm up`,
# docs/LOCAL_STACK.md) pass by prefix: flags, never credentials.
# A desk exports these EMPTY so dotenv cannot load the primary's real mail
# credentials; an empty one is kept, a set one is dropped like any secret.
TM_ENV_KEEP_IF_EMPTY=(RESEND_API_KEY SES_SMTP_USERNAME SES_SMTP_PASSWORD)
# One spawn may name an extra variable it needs (the Stripe listener's
# STRIPE_API_KEY, which it reads from the environment so the key is never argv).
SPAWN_KEEP_EXTRA=""

# tm_scrub_env — unset every exported name the allow-list does not name. Run it
# in the subshell that execs the child, so this shell keeps its own environment.
# Names only: no value is ever printed or put on a command line.
tm_scrub_env(){
  local name k keep extra="$SPAWN_KEEP_EXTRA"
  for name in $(compgen -e); do
    keep=0
    for k in "${TM_ENV_ALLOW[@]}" $extra; do [ "$name" = "$k" ] && { keep=1; break; }; done
    # Boot flags, and the whole locale family (launchd and `env -i` start with
    # no locale, and Ruby then reads UTF-8 as US-ASCII).
    case "$name" in ENABLE_*|LC_*) keep=1 ;; esac
    if [ "$keep" = 0 ]; then
      for k in "${TM_ENV_KEEP_IF_EMPTY[@]}"; do
        [ "$name" = "$k" ] && [ -z "${!name}" ] && { keep=1; break; }
      done
    fi
    [ "$keep" = 1 ] || unset "$name"
  done
}
