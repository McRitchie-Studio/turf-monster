# Stands in for a configured Solana::PlatformCosigner whose address is
# mainnet's 3LTL (seated in the config signer list), so no test needs that
# key's secret. #sign_wire_base64 wraps the bytes so a test can see they were
# signed by the platform and by nothing else.
class FakePlatformCosigner
  GOV_3LTL = "3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9".freeze

  attr_reader :address, :signed

  def initialize(address = GOV_3LTL, configured: true)
    @address = address
    @configured = configured
    @signed = []
  end

  def configured? = @configured
  def notice = "test platform"

  def sign_wire_base64(wire)
    @signed << wire
    "PLATFORM_SIGNED(#{wire})"
  end
end
