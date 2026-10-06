module Admin
  # /admin/experiments — page A/B tests (PageExperiment): create one on a page,
  # edit its variants' copy and weights, pause it, and read its results
  # (ExperimentReport) side by side. No delete: an experiment's counts outlive
  # it, and pausing (active off) stops the split while keeping them.
  class ExperimentsController < ApplicationController
    before_action :require_admin
    before_action :set_experiment, only: %i[show edit update]

    # Blank variant rows the form offers for adding: two on a new experiment
    # (a control and a challenger), one more on an existing one.
    NEW_VARIANT_ROWS = 2

    def index
      @experiments = PageExperiment.includes(:variants).order(active: :desc, created_at: :desc).to_a
      @reports = @experiments.to_h { |experiment| [experiment.slug, ExperimentReport.new(experiment, window: params[:days])] }
      @short_links = CampaignLink.all.to_a.group_by(&:experiment_slug)
    end

    def show
      @report = ExperimentReport.new(@experiment, window: params[:days])
      @short_links = CampaignLink.all.select { |link| link.experiment_slug == @experiment.slug }
    end

    def new
      @experiment = PageExperiment.new(page_path: params[:page_path], active: true)
      @experiment.variants.build(key: PageExperiment::CONTROL_KEY, label: "Control (the page as it is)", weight: 1, position: 0)
      @experiment.variants.build(weight: 1, position: 1)
    end

    def create
      @experiment = PageExperiment.new(experiment_params)
      return render_form(:new) if @experiment.invalid?

      rescue_and_log(target: @experiment) do
        @experiment.save!
        redirect_to admin_experiment_path(@experiment), notice: %(Experiment "#{@experiment.name}" created.)
      end
    end

    def edit
      @experiment.variants.build(weight: 0, position: @experiment.variants.size)
    end

    def update
      @experiment.assign_attributes(experiment_params)
      return render_form(:edit) if @experiment.invalid?

      rescue_and_log(target: @experiment) do
        @experiment.save!
        redirect_to admin_experiment_path(@experiment), notice: %(Experiment "#{@experiment.name}" saved.)
      end
    end

    private

    def set_experiment
      @experiment = PageExperiment.includes(:variants).find_by(slug: params[:slug])
      redirect_to admin_experiments_path, alert: "Experiment not found." unless @experiment
    end

    def render_form(action)
      render action, status: :unprocessable_entity
    end

    def experiment_params
      permitted = params.require(:page_experiment).permit(
        :slug, :name, :page_path, :active,
        variants_attributes: %i[id key label weight position headline subhead_desktop subhead_mobile
                                meta_title meta_description _destroy]
      )
      permitted.delete(:slug) if @experiment&.persisted?
      permitted
    end
  end
end
