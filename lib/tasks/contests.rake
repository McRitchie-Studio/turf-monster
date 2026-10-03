# Contest maintenance one-offs.
namespace :contests do
  # Move open, not-yet-locked NFL contests from the old lock (the slate's first
  # kickoff — Thursday on a TNF week) to the opening-Sunday lock
  # (Contest::LockRule). Every guard and the signing path are documented in
  # Contests::ApplyNflSundayLock; read it before WRITE=1.
  #
  #   bin/rails contests:nfl_sunday_lock                       # dry run, every open NFL contest
  #   SLUGS=a,b bin/rails contests:nfl_sunday_lock             # dry run, named contests only
  #   WRITE=1 SLUGS=a,b bin/rails contests:nfl_sunday_lock     # move them (chain first, then DB)
  #
  # Exits 1 when a write was attempted and any contest errored.
  desc "Move open NFL contests' lock to 11:00 Denver on the opening Sunday (dry run unless WRITE=1)"
  task nfl_sunday_lock: :environment do
    write = ENV["WRITE"] == "1"
    rows = Contests::ApplyNflSundayLock.new(write: write, slugs: ENV["SLUGS"].to_s.split(",")).call
    exit 1 if write && rows.any? { |row| row.action == :error }
  end
end
