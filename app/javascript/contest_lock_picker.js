// Contest lock-time picker — sport pills + calendar + time input + tz snapshot.
// Used in both /contests/new and /contests/edit. Identical 80-line x-data was
// inline in both views before this extraction. Differences between the two
// flows are handled via opts:
//   - opts.sport ('fifa' | 'nfl'): /new only — autofires the sport's default
//     lockDate/Time and view month on init (the FIFA/NFL pills still call
//     selectFifa()/selectNfl() directly for explicit user toggles).
//   - opts.slateId + opts.slateStarts: /new only — hydrates the picker from the
//     selected slate's first game kickoff before falling back to sport defaults.
//   - opts.utcIso (ISO 8601 string): /edit only — hydrates lockDate/Time from
//     the server-rendered contest.starts_at and skips the sport-default path.
//   - opts.onchain + opts.slug: /edit only — the contest's lock lives on chain,
//     so the picked moment goes to Phantom (lockViaPhantom) instead of riding
//     the form. The view omits the hidden fields entirely in that case.
//
// Writes through hidden form fields:
//   #contest_starts_at, #locks_at_date_selected, #locks_at_time_selected,
//   #locks_at_timezone_selected — OPTIONAL. sync() returns early when
//   #contest_starts_at is absent, which is exactly what an on-chain contest's
//   edit page renders: the picker still drives the UI, but nothing about the
//   lock is submitted with the form.

function contestLockPicker(opts) {
  opts = opts || {};
  return {
    sport: opts.sport || '',
    slateId: opts.slateId ? String(opts.slateId) : '',
    slateStarts: opts.slateStarts || {},
    lockDate: '',
    lockTime: '',
    calOpen: false,
    viewYear: new Date().getFullYear(),
    viewMonth: new Date().getMonth(),
    tzAbbr: (function() {
      var s = new Date().toLocaleTimeString('en-US', { timeZoneName: 'short' });
      return s.split(' ').pop();
    })(),
    tzIana: Intl.DateTimeFormat().resolvedOptions().timeZone,
    months: ['January','February','March','April','May','June','July','August','September','October','November','December'],
    days: ['Su','Mo','Tu','We','Th','Fr','Sa'],

    init: function() {
      if (opts.utcIso) {
        this.applyUtcIso(opts.utcIso);
        return;
      }
      if (this.slateId && this.selectSlate(this.slateId)) return;
      if (this.sport === 'fifa') this.selectFifa();
      else if (this.sport === 'nfl') this.selectNfl();
    },

    applyUtcIso: function(iso) {
      var local = new Date(iso);
      if (isNaN(local.getTime())) return false;
      this.lockDate = local.getFullYear() + '-' + String(local.getMonth() + 1).padStart(2, '0') + '-' + String(local.getDate()).padStart(2, '0');
      this.lockTime = String(local.getHours()).padStart(2, '0') + ':' + String(local.getMinutes()).padStart(2, '0');
      this.viewYear = local.getFullYear();
      this.viewMonth = local.getMonth();
      this.sync();
      return true;
    },

    selectSlate: function(id) {
      this.slateId = String(id || '');
      var iso = this.slateStarts[this.slateId];
      return iso ? this.applyUtcIso(iso) : false;
    },

    sync: function() {
      var hidden   = document.getElementById('contest_starts_at');
      var dateSnap = document.getElementById('locks_at_date_selected');
      var timeSnap = document.getElementById('locks_at_time_selected');
      var tzSnap   = document.getElementById('locks_at_timezone_selected');
      if (!hidden) return;
      if (this.lockDate && this.lockTime) {
        var local = new Date(this.lockDate + 'T' + this.lockTime);
        hidden.value   = local.toISOString().substring(0, 16);
        dateSnap.value = this.lockDate;
        timeSnap.value = this.lockTime;
        tzSnap.value   = this.tzIana;
      } else {
        hidden.value = dateSnap.value = timeSnap.value = tzSnap.value = '';
      }
    },

    selectFifa: function() {
      this.sport = 'fifa';
      if (this.selectSlate(this.slateId)) return;
      this.lockDate = '2026-06-11';
      this.lockTime = '13:00';
      this.viewYear = 2026;
      this.viewMonth = 5;
      this.sync();
    },

    selectNfl: function() {
      this.sport = 'nfl';
      if (this.selectSlate(this.slateId)) return;
      this.lockDate = '2026-09-09';
      this.lockTime = '18:15';
      this.viewYear = 2026;
      this.viewMonth = 8;
      this.sync();
    },

    get displayDate() {
      if (!this.lockDate) return '';
      var parts = this.lockDate.split('-');
      return this.months[parseInt(parts[1]) - 1].substring(0, 3) + ' ' + parseInt(parts[2]) + ', ' + parts[0];
    },

    prevMonth: function() {
      if (this.viewMonth === 0) { this.viewMonth = 11; this.viewYear--; }
      else { this.viewMonth--; }
    },

    nextMonth: function() {
      if (this.viewMonth === 11) { this.viewMonth = 0; this.viewYear++; }
      else { this.viewMonth++; }
    },

    calDays: function() {
      var first = new Date(this.viewYear, this.viewMonth, 1).getDay();
      var count = new Date(this.viewYear, this.viewMonth + 1, 0).getDate();
      var cells = [];
      for (var i = 0; i < first; i++) cells.push(null);
      for (var d = 1; d <= count; d++) cells.push(d);
      return cells;
    },

    pickDay: function(d) {
      var m  = String(this.viewMonth + 1).padStart(2, '0');
      var dd = String(d).padStart(2, '0');
      this.lockDate = this.viewYear + '-' + m + '-' + dd;
      this.calOpen = false;
      this.sync();
    },

    isSelected: function(d) {
      if (!this.lockDate) return false;
      var m  = String(this.viewMonth + 1).padStart(2, '0');
      var dd = String(d).padStart(2, '0');
      return this.lockDate === this.viewYear + '-' + m + '-' + dd;
    },

    isToday: function(d) {
      var t = new Date();
      return d === t.getDate() && this.viewMonth === t.getMonth() && this.viewYear === t.getFullYear();
    },

    // Unix SECONDS for the currently picked local date+time, or null when the
    // picker is empty. The chain stores seconds, so this is the unit the whole
    // lock path speaks; `new Date(...)` reads the pair as local time, which is
    // what the operator chose in front of the tz label the view prints.
    pickedUnix: function() {
      if (!this.lockDate || !this.lockTime) return null;
      var local = new Date(this.lockDate + 'T' + this.lockTime);
      if (isNaN(local.getTime())) return null;
      return Math.floor(local.getTime() / 1000);
    },

    lockViaPhantom: function() {
      var ts = this.pickedUnix();
      if (ts === null) {
        window.alert('Pick a date and time first.');
        return;
      }
      window.lockContestAtViaPhantom(opts.slug, ts);
    },

    clearLockViaPhantom: function() {
      window.clearContestLockViaPhantom(opts.slug);
    }
  };
}

// Expose globally so x-data="contestLockPicker(...)" resolves at Alpine
// init time. Also register with Alpine.data() defensively so the factory is
// available regardless of module/Alpine load order — mirrors the pattern
// used by solana_stores.js (registerWalletStore).
window.contestLockPicker = contestLockPicker;
function registerContestLockPicker() {
  if (typeof Alpine === 'undefined') return false;
  Alpine.data('contestLockPicker', contestLockPicker);
  return true;
}
if (!registerContestLockPicker()) {
  document.addEventListener('alpine:init', registerContestLockPicker);
}
