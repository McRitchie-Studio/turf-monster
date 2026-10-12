require "test_helper"

# [unit] The signer queue the browser collects, and the check the broadcast
# runs against it, as plain method calls on the controller.
class Admin::AuthoritiesSignerQueueTest < ActiveSupport::TestCase
  ALEX  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  ALEX2 = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze

  def server = Solana::CosignPlan.admin_address

  def controller(params = {})
    Admin::AuthoritiesController.new.tap do |c|
      c.params = ActionController::Parameters.new(params)
    end
  end

  def server_led = { server_leads: true, lead_signer: server, authorizers: [server, ALEX, MASON] }
  def operator_led = { server_leads: false, lead_signer: ALEX, authorizers: [ALEX, MASON] }

  test "server-led signer_queue omits the server's lead" do
    assert_equal [ALEX, MASON], controller.send(:signer_queue_for, server_led)
  end

  test "operator-led signer_queue keeps the full list, lead first" do
    assert_equal [ALEX, MASON], controller.send(:signer_queue_for, operator_led)
  end

  test "a plan armed server-led keeps the lead once this process holds another key" do
    plan = server_led.merge(lead_signer: ALEX2, authorizers: [ALEX2, ALEX])
    assert_equal [ALEX2, ALEX], controller.send(:signer_queue_for, plan)
  end

  test "require_signer_queue! accepts the server-led queue and returns every signer" do
    c = controller(signer_queue: [ALEX, MASON])
    assert_equal [server, ALEX, MASON], c.send(:require_signer_queue!, server_led)
  end

  test "require_signer_queue! refuses a server-led queue that claims the lead" do
    c = controller(signer_queue: [server, ALEX, MASON])
    assert_raises(RuntimeError) { c.send(:require_signer_queue!, server_led) }
  end

  test "require_signer_queue! refuses an operator-led queue without the lead" do
    assert_raises(RuntimeError) { controller(signer_queue: [MASON]).send(:require_signer_queue!, operator_led) }
    assert_raises(RuntimeError) { controller(cosigner_address: MASON).send(:require_signer_queue!, operator_led) }
    assert_equal [ALEX, MASON], controller(signer_queue: [ALEX, MASON]).send(:require_signer_queue!, operator_led)
  end

  test "server-held cosigners are never queued for Phantom" do
    plan = server_led.merge(server_held: [MASON])
    assert_equal [ALEX], controller.send(:signer_queue_for, plan)
  end

  test "broadcast refuses a queue that names a server-held key" do
    plan = server_led.merge(server_held: [MASON])
    assert_raises(RuntimeError) { controller(signer_queue: [ALEX, MASON]).send(:require_signer_queue!, plan) }
    assert_equal [server, ALEX, MASON], controller(signer_queue: [ALEX]).send(:require_signer_queue!, plan)
  end
end
