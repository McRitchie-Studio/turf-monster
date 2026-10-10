// The contract page's deploy-cost calculator. No DOM.

// The SOL price a typed field holds: a number, or 0 when the field is empty or
// not a number (an empty price prices everything at $0).
export function solPrice(raw) {
  const price = raw === "" || raw == null ? NaN : parseFloat(raw)
  return Number.isNaN(price) ? 0 : price
}

export function fmtSol(n) {
  return Number(n).toFixed(3)
}

export function fmtUsd(n) {
  return "$" + Math.round(Number(n)).toLocaleString()
}

// Every readout the calculator shows, by name, for the measured lamports and a
// SOL price. permanent = ProgramData rent + program-account rent + deploy fees;
// float = everything on hand at deploy time; buffer = float less permanent,
// refunded when the buffer closes.
export function readouts({ permLamports, floatLamports }, price) {
  const permSol = permLamports / 1e9
  const floatSol = floatLamports / 1e9
  const bufferSol = floatLamports / 1e9 - permLamports / 1e9
  return {
    floatSol: fmtSol(floatSol),
    floatUsd: fmtUsd(floatSol * price),
    permSol: "~" + fmtSol(permSol) + " SOL",
    permUsd: "~" + fmtUsd(permSol * price),
    bufferSol: "~" + fmtSol(bufferSol) + " SOL",
    bufferUsd: "~" + fmtUsd(bufferSol * price),
    floatSolApprox: "~" + fmtSol(floatSol) + " SOL"
  }
}
