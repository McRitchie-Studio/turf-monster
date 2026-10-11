// The rule behind the usdc-balance controller. No DOM.

// The figure to show from /admin/usdc_balance, or null to keep the one on
// screen: the endpoint answers a null balance when its chain reads failed.
export function balanceText(data) {
  if (!data || data.balance == null) return null
  return parseFloat(data.balance).toFixed(2)
}
