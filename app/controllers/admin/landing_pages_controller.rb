module Admin
  class LandingPagesController < ApplicationController
    before_action :require_admin
    before_action :set_landing_page, only: %i[edit update destroy update_og_image]
    before_action :load_contests,    only: %i[new create edit update]

    def index
      @landing_pages = LandingPage.includes(:contest).order(created_at: :desc)
    end

    def new
      @landing_page = LandingPage.new
    end

    def create
      @landing_page = LandingPage.new(landing_page_params)
      return render :new, status: :unprocessable_entity if @landing_page.invalid?

      rescue_and_log(target: @landing_page) do
        @landing_page.save!
        redirect_to admin_landing_pages_path, notice: %(Landing page "#{@landing_page.name}" created.)
      end
    end

    def edit; end

    # A persisted slug changes only through rename_slug!; a blank field
    # re-derives it from the name.
    def update
      attributes = landing_page_params
      slug = attributes.delete(:slug)
      @landing_page.assign_attributes(attributes)
      return render :edit, status: :unprocessable_entity if @landing_page.invalid?

      rescue_and_log(target: @landing_page) do
        LandingPage.transaction do
          @landing_page.rename_slug!(slug.presence || @landing_page.name.to_s.parameterize) unless slug.nil?
          @landing_page.save!
        end
        redirect_to admin_landing_pages_path, notice: %(Landing page "#{@landing_page.name}" updated.)
      rescue Sluggable::SlugRefused
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      rescue_and_log(target: @landing_page) do
        @landing_page.destroy!
        redirect_to admin_landing_pages_path, notice: "Landing page deleted."
      end
    end

    # Immediate cropper save for the per-page link-preview image (mirrors the
    # contest banner flow — its own multipart form, refreshes the preview via
    # Turbo). Edit-only: the record must exist to attach to.
    def update_og_image
      rescue_and_log(target: @landing_page) do
        file = params.dig(:landing_page, :og_image)

        if valid_image?(file)
          @landing_page.og_image.attach(file)
          respond_to do |format|
            format.turbo_stream do
              render turbo_stream: turbo_stream.replace(
                "landing-og-image-preview",
                partial: "admin/shared/og_image_preview",
                locals: { dom_id: "landing-og-image-preview", attachment: @landing_page.og_image,
                          alt: "Link-preview image", fallback: "No custom image — falls back to the site default, then /og.png" }
              )
            end
            format.html { redirect_to edit_admin_landing_page_path(@landing_page), notice: "Link-preview image updated." }
          end
        else
          message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
          redirect_to edit_admin_landing_page_path(@landing_page), alert: message, status: :see_other
        end
      end
    end

    private

    def set_landing_page
      @landing_page = LandingPage.find_by(slug: params[:slug])
      redirect_to admin_landing_pages_path, alert: "Landing page not found." unless @landing_page
    end

    def load_contests
      # All contests — a landing page can funnel to any of them.
      @contests = Contest.order(created_at: :desc)
    end

    def landing_page_params
      # :og_image is permitted for programmatic/seed attach; the admin UI sets
      # it via the immediate-save update_og_image endpoint (the cropper submits
      # its own form), not through this main form.
      params.require(:landing_page).permit(:name, :slug, :headline, :subheadline, :badge, :cta_label, :contest_id, :active, :claim_mode, :background_style, :og_image)
    end
  end
end
