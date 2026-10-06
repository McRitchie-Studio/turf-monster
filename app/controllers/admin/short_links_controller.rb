module Admin
  # /admin/short_links — campaign short links (CampaignLink): a human-named
  # /l/<token> that sends a click to a page on this site tagged ?r=<reference>.
  # Create, edit, disable and re-enable; never delete (a link already printed in
  # a bio keeps being clicked). The click column reads ReferralReport.
  class ShortLinksController < ApplicationController
    before_action :require_admin
    before_action :set_short_link, only: %i[edit update toggle]

    def index
      @short_links = CampaignLink.newest_first.to_a
      @clicks = ReferralReport.clicks_for(@short_links.map(&:reference))
    end

    def new
      @short_link = CampaignLink.new(target_path: params[:target_path], reference: params[:reference])
    end

    def create
      @short_link = CampaignLink.new(short_link_params)
      return render :new, status: :unprocessable_entity if @short_link.invalid?

      rescue_and_log(target: @short_link) do
        @short_link.save!
        redirect_to admin_short_links_path, notice: %(Short link "/l/#{@short_link.token}" created.)
      end
    end

    def edit; end

    def update
      @short_link.assign_attributes(short_link_params)
      return render :edit, status: :unprocessable_entity if @short_link.invalid?

      rescue_and_log(target: @short_link) do
        @short_link.save!
        redirect_to admin_short_links_path, notice: %(Short link "/l/#{@short_link.token}" updated.)
      end
    end

    # PATCH /admin/short_links/:token/toggle — disable a live link, or re-enable
    # a disabled one.
    def toggle
      rescue_and_log(target: @short_link) do
        @short_link.active? ? @short_link.disable! : @short_link.enable!
        state = @short_link.active? ? "enabled" : "disabled"
        redirect_to admin_short_links_path, notice: %(Short link "/l/#{@short_link.token}" #{state}.)
      end
    end

    private

    def set_short_link
      @short_link = CampaignLink.find_by(token: params[:token])
      redirect_to admin_short_links_path, alert: "Short link not found." unless @short_link
    end

    def short_link_params
      params.require(:campaign_link).permit(:token, :target_path, :reference, :experiment_slug)
    end
  end
end
