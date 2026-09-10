# frozen_string_literal: true

require "test_helper"

# [component] transparency-pins-mainnet-program — the public /transparency page
# names the MAINNET program on every cluster, on purpose.
#
# THE DECISION. Mr. McRitchie, 2026-09-10, option (b): pin the live product's
# program ID everywhere, QA/devnet included. The page makes claims about the
# live product to external reviewers (it is the page cited in the Phantom /
# Blowfish de-list appeal), and for that reader an address that changes by
# environment is worse than a constant one. The reason is written beside the
# literal in app/views/transparency/show.html.erb, and the last test here keeps
# it there.
#
# THE OPPOSITE OF THE ADMIN CARD, deliberately. ContractProgramIdCaptionTest and
# ContractUpgradeAuthorityTest require the operator-facing admin card to FOLLOW
# the cluster. This file requires the public page NOT to. Same technique,
# opposite assertion, because the two pages have opposite readers.
#
# WHY IT DRIVES BOTH CLUSTERS. The mainnet render alone passes against a view
# that reads Solana::Config::PROGRAM_ID, because on a mainnet build that
# constant IS the mainnet program. The devnet render is the case that bites: a
# per-cluster "fix" shows the devnet program there, and this goes red.
#
# WHERE THE EXPECTED ADDRESS COMES FROM. Not from the view, which would certify
# whatever the view says. It is read from the committed mainnet IDL, the app's
# own record of the program it talks to on mainnet, so a mainnet redeploy to a
# new address turns this red instead of leaving the pin quietly stale.
#
# THE CLUSTER SWAP. PROGRAM_ID and NETWORK are LOAD-TIME constants (OPSEC-012 in
# config.rb), so swapping the constants is the only way to put this process on
# the other cluster. `with_network` is copied from ContractUpgradeAuthorityTest
# (admin-shows-devnet-authority, turf PR 549); `with_program_id` is the same
# technique on the sibling constant. Rails parallelises by FORK, so neither swap
# crosses workers. The layout's data-solana-cluster attribute reads NETWORK on
# every render and each case asserts it, so a swap that did not take fails here
# instead of rendering the same page twice.
class TransparencyProgramIdTest < ActionDispatch::IntegrationTest
  VIEW = "app/views/transparency/show.html.erb"

  MAINNET_PROGRAM = JSON.parse(Rails.root.join("config/turf_vault.mainnet.idl.json").read).fetch("address")
  DEVNET_PROGRAM  = JSON.parse(Rails.root.join("config/turf_vault.idl.json").read).fetch("address")

  # The one <code> under test, by its data-test hook. The page also carries a
  # navbar, a footer and meta tags; a body-wide match reads all of them. Returns
  # nil when the callout did not render, so nothing below passes vacuously.
  def program_id_in_callout(body)
    body[%r{<code[^>]*data-test="transparency-program-id"[^>]*>(.*?)</code>}m, 1]&.strip
  end

  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  def with_program_id(program_id)
    previous = Solana::Config::PROGRAM_ID
    Solana::Config.send(:remove_const, :PROGRAM_ID)
    Solana::Config.const_set(:PROGRAM_ID, program_id)
    yield
  ensure
    Solana::Config.send(:remove_const, :PROGRAM_ID)
    Solana::Config.const_set(:PROGRAM_ID, previous)
  end

  # One render per cluster configuration. A failure names the cluster.
  def assert_pins_mainnet(network:, program_id:)
    with_program_id(program_id) do
      with_network(network) do
        get transparency_path
        assert_response :success

        assert_includes response.body, %(data-solana-cluster="#{network}"),
          "#{network}: the layout did not render as a #{network} build, so the swap did not take " \
          "and this case would only repeat the other one"

        rendered = program_id_in_callout(response.body)
        assert rendered.present?,
          "#{network}: the Program & Authority callout rendered no program ID - the assertions " \
          "below would pass vacuously"
        assert_equal MAINNET_PROGRAM, rendered,
          "#{network}: the public page must name the MAINNET program on every cluster " \
          "(decided 2026-09-10; the reason is in #{VIEW})"

        unless program_id == MAINNET_PROGRAM
          assert_no_match(/#{Regexp.escape(program_id)}/, response.body,
            "#{network}: the build's own program ID appears on the page. The public page is " \
            "pinned to mainnet on purpose; do not render Solana::Config::PROGRAM_ID here")
        end
      end
    end
  end

  test "a devnet build still names the MAINNET program" do
    assert_not_equal MAINNET_PROGRAM, DEVNET_PROGRAM,
      "the committed IDLs name the same program, so the devnet case cannot tell a pin " \
      "from a per-cluster read"

    assert_pins_mainnet(network: "devnet", program_id: DEVNET_PROGRAM)
  end

  test "a mainnet build names the MAINNET program" do
    assert_pins_mainnet(network: "mainnet-beta", program_id: MAINNET_PROGRAM)
  end

  # ACCEPTANCE 1 IS THE REASON, not the address. A bare address with no comment
  # is how this family of defects began: the next agent reads a hard-coded ID,
  # takes it for a bug, and "fixes" it to per-cluster. So the nearest ERB
  # comment above the literal must carry the decision. It scans SOURCE because
  # an ERB comment never reaches the rendered page.
  test "the pin carries its reason beside it" do
    source = Rails.root.join(VIEW).read

    literal_at = source.index(MAINNET_PROGRAM)
    assert literal_at, "#{VIEW} no longer names #{MAINNET_PROGRAM} - this guard would pass vacuously"

    opener = source.rindex("<%#", literal_at)
    assert opener, "#{VIEW} has no ERB comment above the pinned program ID"
    comment = source[opener...source.index("%>", opener)]

    assert_match(/PINNED TO MAINNET ON EVERY CLUSTER, ON PURPOSE/, comment,
      "the comment nearest the pinned ID must say the pin is deliberate")
    assert_match(/Mr\. McRitchie on 2026-09-10/, comment,
      "the comment must record who decided and when, so the pin is not mistaken for an accident")
    assert_match(/do not "fix" it to per-cluster/, comment,
      "the comment must tell the next agent not to reverse the decision")
  end
end
