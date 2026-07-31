// Slate Simulator — runs a 30s accelerated game simulation (10 ticks at 3s intervals)
// Each tick: P(goal) = expected_score / 10 for each team
//
// Usage:
//   import { simulateGame } from "slate_simulator"
//   const handle = simulateGame(gameData, { onGoal, onTick, onComplete })
//   handle.cancel() // to abort

const TICKS = 10;
const TICK_INTERVAL = 3000;

export function simulateGame(gameData, callbacks = {}) {
  const { onGoal, onTick, onComplete } = callbacks;
  const homeET = gameData.home?.expectedScore || 1.5;
  const awayET = gameData.away?.expectedScore || 1.5;
  const homeProb = homeET / TICKS;
  const awayProb = awayET / TICKS;
  const homePlayers = gameData.home?.players || [];
  const awayPlayers = gameData.away?.players || [];

  let tick = 0;
  let cancelled = false;

  const interval = setInterval(async () => {
    if (cancelled) { clearInterval(interval); return; }
    tick++;

    // Home team chance
    if (Math.random() < homeProb) {
      const player = homePlayers.length ? homePlayers[Math.floor(Math.random() * homePlayers.length)] : null;
      const minute = (tick - 1) * 9 + Math.floor(Math.random() * 9) + 1;
      if (onGoal) await onGoal({ teamSlug: gameData.home.slug, playerSlug: player?.slug, minute }, gameData);
    }

    // Away team chance
    if (Math.random() < awayProb) {
      const player = awayPlayers.length ? awayPlayers[Math.floor(Math.random() * awayPlayers.length)] : null;
      const minute = (tick - 1) * 9 + Math.floor(Math.random() * 9) + 1;
      if (onGoal) await onGoal({ teamSlug: gameData.away.slug, playerSlug: player?.slug, minute }, gameData);
    }

    if (onTick) onTick(tick, TICKS);

    if (tick >= TICKS) {
      clearInterval(interval);
      if (onComplete) onComplete(gameData.slug);
    }
  }, TICK_INTERVAL);

  return {
    cancel() {
      cancelled = true;
      clearInterval(interval);
    }
  };
}

// Attach to window for inline script compatibility
window.simulateGame = simulateGame;
