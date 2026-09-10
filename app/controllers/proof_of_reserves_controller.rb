class ProofOfReservesController < ApplicationController
  skip_before_action :require_authentication

  def show
    @contests = Contest.where(status: [:open, :settled])
                       .where.not(onchain_contest_id: nil)
                       .order(created_at: :desc)

    # v0.16: there is no single shared USDC vault — each contest's reserve sits
    # in its own prize_pool token account. We hand the browser each contest's
    # prize_pool PDA and it reads the live balance directly from chain.
    @vault = Solana::Vault.new

    @page_config = {
      # This page is PUBLIC and renders the endpoint as visible text, so it
      # gets the browser endpoint, never the server's keyed RPC_URL.
      rpc_url:    Solana::Config.public_rpc_url,
      program_id: Solana::Config::PROGRAM_ID,
      usdc_mint:  Solana::Config::USDC_MINT,
      network:    Solana::Config::NETWORK,
      contests:   @contests.map { |c| contest_payload(c) }
    }
  end

  private

  def contest_payload(c)
    prize_pool_bytes, _bump = @vault.prize_pool_pda(c.slug)
    {
      slug:                c.slug,
      name:                c.name,
      contest_pda:         c.onchain_contest_id,
      prize_pool_pda:      Solana::Keypair.encode_base58(prize_pool_bytes),
      create_tx_signature: c.onchain_tx_signature,
      created_label:       c.created_at.strftime("%B %Y")
    }
  end
end
