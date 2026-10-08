# Solana::Deadline::ClientCall goes over Solana::Client#call after
# Solana::ClientLogger (outbound_request_hooks.rb, an earlier file), so it is
# the outer wrapper: a call the deadline refuses writes no outbound_requests row.
Rails.application.config.to_prepare do
  Solana::Client.prepend(Solana::Deadline::ClientCall)
end
