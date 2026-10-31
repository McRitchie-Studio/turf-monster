// Turf board utilities
// selectionBoard stays inline in _turf_totals_board.html.erb (Alpine timing constraint)

// Auto-shrink long team names, a step at a time down the type scale (task
// turf-adopts-type-scale): body first, then fine print, the nearest role to the
// 0.7rem this used to jump straight to.
var TEAM_NAME_STEPS = ['calc(var(--type-base, 16px) * 1)', 'calc(var(--type-base, 16px) * 0.75)'];
function shrinkTeamNames() {
  document.querySelectorAll('.team-name').forEach(function(el) {
    el.style.fontSize = '';
    for (var i = 0; i < TEAM_NAME_STEPS.length && el.scrollWidth > el.clientWidth; i++) {
      el.style.fontSize = TEAM_NAME_STEPS[i];
    }
  });
}
window.shrinkTeamNames = shrinkTeamNames;

document.addEventListener('turbo:load', shrinkTeamNames);
document.addEventListener('alpine:initialized', function() { setTimeout(shrinkTeamNames, 100); });
