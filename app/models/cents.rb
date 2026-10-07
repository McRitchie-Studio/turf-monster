# Whole cents from a dollar amount a person typed ("2.01", 25, "100").
#
# Parsed through BigDecimal and floored, so it never passes through a Float:
# `"2.01".to_f * 100` is 200.99999999999997, and `to_i` turns that into a
# $2.00 request. Blank or unparseable input is 0, which every caller already
# refuses as "not positive". Integer cents then reach the chain only through
# Solana::Config.cents_to_base_units.
module Cents
  module_function

  def from_dollars(value)
    dollars = BigDecimal(value.to_s.strip, exception: false)
    return 0 unless dollars&.finite?

    (dollars * 100).floor.to_i
  end
end
