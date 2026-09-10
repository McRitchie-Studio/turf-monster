# frozen_string_literal: true

require "test_helper"

# [integration] THE CONTEST BANNER MUST SURVIVE A PAGE DEATH.
#
# THE DEFECT THIS EXISTS FOR. The banner used to ride the FINALIZE post as an
# uploaded File. On the redirect transport — every ordinary mobile browser — the
# document holding that File is DESTROYED while the wallet signs, and the
# finalize POST is made by studio-engine's callback page, which has no form and
# no file input. A File cannot be written to the wallet journal, so the image
# would have vanished with no error anywhere: a contest created, funded, and
# silently unbranded, discovered only by looking at it.
#
# THE FIX, asserted here end to end: #create stashes the upload as an unattached
# blob and binds its signed id to the params_token, so #finalize can attach it
# from the token on a request that carries no file at all.
class ContestsBannerSurvivesRedirectTest < ActionDispatch::IntegrationTest
  setup do
    @slate = slates(:one)
    SeasonConfig.set_current!(1)
  end

  def admin_phantom
    @admin_phantom ||= User.create!(
      name: "Banner Admin", username: "banner_admin", role: :admin,
      email: "banner_admin@mcritchie.studio",
      web3_solana_address: "BaNNerAdMiN111111111111111111111111111111111"
    )
  end

  def uploaded_banner
    Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/banner.png"), "image/png")
  end

  # Step 1, over the wire the browser actually uses: multipart, WITH the file.
  # The client stopped stripping it — that change is the whole point.
  def run_create(slug:, name:, image: uploaded_banner)
    attrs = { name: name, slug: slug, slate_id: @slate.id, contest_type: "tiny" }
    attrs[:contest_image] = image if image

    json = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post contests_path, params: { contest: attrs }
      json = JSON.parse(response.body)
    end
    assert_equal true, json["success"], "create step failed: #{json.inspect}"
    json
  end

  # Step 3 as the CALLBACK DOCUMENT makes it: JSON, no file, nothing but the
  # signed wire and the two ids the journal carried.
  def run_finalize(create_json)
    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_contests_path,
               params: { params_token: create_json["params_token"],
                         contest_pda: create_json["contest_pda"],
                         signed_tx: "SIGNED_CREATE_WIRE" },
               as: :json
        end
      end
    end
  end

  test "a banner picked before the wallet trip is attached by a finalize carrying no file" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "banner-crosses", name: "Banner Crosses")

    run_finalize(create_json)

    assert_response :success
    assert_equal true, response.parsed_body["success"], "precondition: this finalize must have SUCCEEDED"
    contest = Contest.find_by!(slug: "banner-crosses")
    assert contest.contest_image.attached?,
           "the image was chosen on a page that no longer exists by the time finalize runs — " \
           "if it only travels as a File, every mobile contest ships unbranded"
    assert_equal "banner.png", contest.contest_image.filename.to_s,
                 "and it must be THE file the operator picked, not some other attachment"
  end

  test "a create with no image leaves finalize with nothing to attach" do
    # THE CONTROL. Without it the assertion above would pass just as well if
    # something else in the create path attached a default image — the test would
    # be reading a fixture rather than the mechanism.
    log_in_as(admin_phantom)
    create_json = run_create(slug: "banner-absent", name: "Banner Absent", image: nil)

    run_finalize(create_json)

    assert_response :success
    contest = Contest.find_by!(slug: "banner-absent")
    refute contest.contest_image.attached?
  end

  test "a banner that cannot be stashed does not fail the contest" do
    # A contest whose image failed to upload is a contest with no image. Refusing
    # to build the transaction over it would cost the operator the whole flow for
    # the least important field on the form — the same rule the attach side has
    # always followed.
    log_in_as(admin_phantom)
    create_json = nil
    ActiveStorage::Blob.stub :create_and_upload!, ->(*) { raise "S3 is down" } do
      create_json = run_create(slug: "banner-flaked", name: "Banner Flaked")
    end

    run_finalize(create_json)

    assert_response :success
    assert_equal true, response.parsed_body["success"],
                 "an S3 outage must not stop a contest from being created and funded"
    refute Contest.find_by!(slug: "banner-flaked").contest_image.attached?,
           "the control: the stash really did fail"
  end

  test "a file posted directly to finalize still wins" do
    # THE OLD SHAPE STILL WORKS. Nothing about this change forbids a caller that
    # holds the file at finalize time from posting it — an inline desktop flow
    # could, and a future one might. The stash is the fallback, not a replacement.
    log_in_as(admin_phantom)
    create_json = run_create(slug: "banner-direct", name: "Banner Direct", image: nil)

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_contests_path,
               params: { params_token: create_json["params_token"],
                         contest_pda: create_json["contest_pda"],
                         signed_tx: "SIGNED_CREATE_WIRE",
                         contest_image: uploaded_banner }
        end
      end
    end

    assert_response :success
    assert Contest.find_by!(slug: "banner-direct").contest_image.attached?
  end
end
