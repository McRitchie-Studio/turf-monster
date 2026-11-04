require "test_helper"

# routes.rb draws these two unless production, which admits a staging or review-app dyno.
class TestControllerFigureGatesTest < ActionDispatch::IntegrationTest
  %w[staging production].each do |name|
    test "[component] warm_balance and wallet_export_link refuse a #{name}-shaped env" do
      log_in_as(users(:alex))
      Rails.stub :env, ActiveSupport::StringInquirer.new(name) do
        post "/test/warm_balance", params: { usdc: 1 }
        assert_response :forbidden
        post "/test/wallet_export_link"
        assert_response :forbidden
      end
    end
  end
end
