# frozen_string_literal: true

require "test_helper"
require "digest"

# [component] contract-page-byte-data-stale — the /contract page's byte and rent
# figures must describe the DEPLOYED program, and say which version they measured.
#
# THE BUG. app/views/contract/show.html.erb hand-maintained binary_size = 501_528
# and per-section byte counts measured on the v0.19 build, and printed them under a
# v0.25 version pill. It also computed the "forever-locked" rent from the binary
# size alone, (binary + 128) x 6960, which leaves out the 45-byte header every
# ProgramData account carries (and any slack it was sized with). On 2026-09-10 the
# mainnet ProgramData account held 545,973 bytes and 3,800,862,960 lamports; the
# page said 501,528 bytes and about 3.49 SOL.
#
# WHAT THIS CAN PIN, AND WHAT IT CANNOT. A test cannot read the chain, so it cannot
# prove the figures are current. It pins the next best thing: the record the figures
# were measured under must name the IDL that is committed for mainnet, by version
# AND by sha256. Re-pinning config/turf_vault.mainnet.idl.json after a turf-vault
# deploy is the moment the program's bytes change, so that turns this red until
# someone re-measures (docs/SOLANA.md, "Also refresh the /contract page"). The hash
# matters because the version alone is weak: turf-vault's unreleased tree still
# reads 0.25.0. A deploy that leaves the IDL byte-identical (a handler-only patch)
# is invisible here; only the chain's program sha256 sees that.
class ContractMeasurementsTest < ActionDispatch::IntegrationTest
  MAINNET_IDL = Rails.root.join("config", "turf_vault.mainnet.idl.json")
  PROGRAMDATA_HEADER_BYTES = 45 # UpgradeableLoaderState::ProgramData: tag 4 + slot 8 + Option<Pubkey> 33
  LAMPORTS_PER_BYTE = 6_960

  def page
    get contract_path
    assert_response :success
    response.body
  end

  def int(text) = text.delete(",").to_i

  def measured_on(body)
    body[%r{<p[^>]*data-test="contract-measured-on"[^>]*>.*?</p>}m]
  end

  def attr(element, name)
    element[/#{name}="([^"]*)"/, 1]
  end

  test "the measured record names the committed mainnet IDL, by version and by hash" do
    idl_bytes = File.read(MAINNET_IDL)
    version = JSON.parse(idl_bytes).dig("metadata", "version")
    assert version.present?, "the mainnet IDL carries no metadata.version - this case would prove nothing"

    element = measured_on(page)
    assert element, "the page rendered no measured-on record, so nothing says which program its figures describe"

    stale = "re-pinned since the /contract figures were measured. Re-measure them from the " \
            "deployed program and update the `measured` block in app/views/contract/show.html.erb " \
            "(docs/SOLANA.md, \"Also refresh the /contract page\")."
    assert_equal version, attr(element, "data-version"), "config/turf_vault.mainnet.idl.json was #{stale}"
    assert_equal Digest::SHA256.hexdigest(idl_bytes), attr(element, "data-idl-sha256"),
      "config/turf_vault.mainnet.idl.json changed (same version, new bytes) - it was #{stale}"

    text = ActionController::Base.helpers.strip_tags(element).squish
    assert_includes text, "v#{version}", "the visible record must name the version it measured"
    assert_match(/slot [\d,]+ \(\d{4}-\d{2}-\d{2}\)/, text, "the visible record must name the slot and date it measured at")
  end

  test "the permanent rent is the ProgramData account's rent, header included" do
    body = page

    binary = body[%r{Deploy binary</div>\s*<div[^>]*>\s*([\d,]+)}m, 1]
    data_len = body[/ProgramData rent \(([\d,]+) \+ 128\)/, 1]
    lamports = body[%r{data-test="contract-pd-rent-lamports"[^>]*>\s*([\d,]+)}m, 1]
    hero_sol = body[%r{Permanent rent</div>\s*<div[^>]*>\s*([\d.]+)}m, 1]
    assert binary && data_len, "the hero binary size or the calculator's ProgramData formula did not render"

    assert_operator int(data_len), :>=, int(binary) + PROGRAMDATA_HEADER_BYTES,
      "rent is charged on the whole ProgramData account: the #{binary}-byte ELF plus a " \
      "#{PROGRAMDATA_HEADER_BYTES}-byte loader header at least. A data_len of #{data_len} leaves the header out."

    assert lamports, "the ProgramData rent line rendered no server-side lamport figure"
    assert_equal (int(data_len) + 128) * LAMPORTS_PER_BYTE, int(lamports),
      "the rent line's lamports must follow the rent formula for the data_len it prints"
    assert_equal format("%.3f", int(lamports) / 1e9), hero_sol,
      "the hero's forever-locked rent must be the ProgramData account's rent, the same figure the calculator itemizes"
  end

  test "figures that were not re-measured say which build they came from" do
    body = page
    measured_version = attr(measured_on(body).to_s, "data-version")
    notes = body.scan(%r{<p[^>]*data-test="contract-attributed-on"[^>]*>.*?</p>}m)

    assert_equal 2, notes.size,
      "the .text buckets and the per-instruction bytes each need a provenance note; found #{notes.size}"
    notes.each do |note|
      built_on = attr(note, "data-version")
      text = ActionController::Base.helpers.strip_tags(note).squish
      assert built_on.present?, "a provenance note carries no version: #{text}"
      assert_includes text, built_on, "the note must show readers the build these bytes came from"
      assert_includes text, "v#{measured_version}", "the note must name the deployed version it has not been re-measured for"
    end
  end

  test "the operator playbook names every committed instruction it does not cover" do
    log_in_as(users(:alex))
    body = page

    idl_names = JSON.parse(File.read(Solana::Config::IDL_PATH))["instructions"].map { |ix| ix["name"] }
    playbook = body[%r{Operator playbook.*?</section>}m]
    assert playbook, "an admin was shown no operator playbook - this case would prove nothing"

    # The note names its instructions in <code> too, so read coverage from the
    # playbook WITHOUT the note, or every missing name would count as covered.
    note = playbook[%r{<p[^>]*data-test="contract-playbook-unlisted"[^>]*>.*?</p>}m].to_s
    audited = playbook.sub(note, "")
    covered = idl_names.select { |n| audited.include?(">#{n}<") }
    missing = idl_names - covered
    assert covered.any?, "no IDL instruction matched the playbook - the matcher is broken, not the page"
    if missing.empty?
      assert_empty note, "the playbook covers every IDL instruction, so it must name none as missing"
      return
    end

    missing.each do |name|
      assert_includes note, ">#{name}<",
        "#{name} is in the committed IDL but neither audited in the playbook nor named as missing from it"
    end
  end
end
