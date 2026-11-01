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
# TWO DISTINCTIONS THE FIRST FIX STILL BLURRED (review, 2026-09-11), each with a
# case below. (1) The loader writes 545,928 bytes and Agave reads that file
# through EOF, so the DEPLOYED FILE is 545,928; 544,904 is only where the ELF's
# logical content ends, and pricing a deploy buffer off it under-funds the
# buffer. (2) An account's funded BALANCE is not today's rent-exempt MINIMUM:
# these accounts were funded at 6,960 lamports a byte and the cluster has been
# lowering that rate (6,333 on 2026-09-11, 5,080 two days later), so a minimum
# must be queried rather than multiplied out.
#
# WHAT THIS CAN PIN, AND WHAT IT CANNOT. A test cannot read the chain, so it cannot
# prove the figures are current. It pins the next best thing: the record the figures
# were measured under must name the program it measured, by version AND by sha256
# (docs/SOLANA.md, "Also refresh the /contract page").
class ContractMeasurementsTest < ActionDispatch::IntegrationTest
  # WHAT THE `measured` BLOCK MEASURED: the v0.25 program, 2026-09-10. That IDL left
  # the tree on 2026-11-01 and mainnet has run v0.26 since 2026-10-12, so these
  # literals record a dated measurement. Re-measure the page and point this at
  # config/turf_vault.mainnet.v026.idl.json.
  MEASURED_VERSION = "0.25.0".freeze
  MEASURED_IDL_SHA256 = "b9b522635894a42f5434f1faa1cd126d146f3042ae2c233acd1dd76a300f7152".freeze
  MAINNET_IDL = Rails.root.join("config", "turf_vault.mainnet.v026.idl.json")
  PROGRAMDATA_HEADER_BYTES = 45 # UpgradeableLoaderState::ProgramData: tag 4 + slot 8 + Option<Pubkey> 33
  BUFFER_HEADER_BYTES = 37      # UpgradeableLoaderState::Buffer: tag 4 + Option<Pubkey> 33
  RETIRED_LAMPORTS_PER_BYTE = 6_960 # the rate these accounts were funded at; the cluster has lowered it since

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

  test "the measured record names the program it measured, by version and by hash" do
    version = MEASURED_VERSION
    element = measured_on(page)
    assert element, "the page rendered no measured-on record, so nothing says which program its figures describe"

    assert_equal version, attr(element, "data-version")
    assert_equal MEASURED_IDL_SHA256, attr(element, "data-idl-sha256")

    text = ActionController::Base.helpers.strip_tags(element).squish
    assert_includes text, "v#{version}", "the visible record must name the version it measured"
    assert_match(/slot [\d,]+ \(\d{4}-\d{2}-\d{2}\)/, text, "the visible record must name the slot and date it measured at")
  end

  # DISTINCTION 1: the DEPLOYED FILE is the whole program region the loader
  # wrote (Agave reads it through EOF). The ELF's logical content ends earlier,
  # and the zeros after it are rented like any other byte. The page may print
  # the ELF endpoint, but only where it is labeled as ELF content, and never as
  # an input to rent — sizing the buffer off it under-prices a deploy.
  test "the deployed file sizes the accounts, and the ELF endpoint appears only as ELF content" do
    body = page

    deployed = body[%r{Deployed program</div>\s*<div[^>]*>\s*([\d,]+)}m, 1]
    elf = body[%r{data-test="contract-elf-content-bytes"[^>]*>\s*([\d,]+)}m, 1]
    pd_space = body[/data-test="contract-pd-rent-min-line"[^>]*data-space="(\d+)"/, 1]
    buffer_space = body[/data-test="contract-buffer-min-line"[^>]*data-space="(\d+)"/, 1]
    assert deployed && elf && pd_space && buffer_space,
      "the hero file size, the ELF-content figure, or a rent line's byte count did not render"
    assert_operator int(elf), :<, int(deployed),
      "the ELF content must be shorter than the deployed file, or this case is testing nothing"

    assert_equal int(deployed) + PROGRAMDATA_HEADER_BYTES, pd_space.to_i,
      "the ProgramData account is the 45-byte loader header plus the whole deployed file"
    assert_equal int(deployed) + BUFFER_HEADER_BYTES, buffer_space.to_i,
      "a deploy buffer holds the whole deployed file, not just its ELF content: pricing it off " \
      "#{elf} under-funds the buffer by #{int(deployed) - int(elf)} bytes"

    # Every printing of the ELF endpoint must sit inside the labeled span.
    labeled = body.scan(%r{data-test="contract-elf-content-bytes"[^>]*>\s*#{Regexp.escape(elf)}}m).size
    assert_equal body.scan(elf).size, labeled,
      "#{elf} is logical ELF content; it appears somewhere that does not say so"
  end

  # DISTINCTION 2: what an account HOLDS is not what it would COST today. These
  # accounts were funded when a rent-exempt byte cost 6,960 lamports; the cluster
  # keeps lowering that rate, so the page's minimums must be QUERIED
  # (getMinimumBalanceForRentExemption), never multiplied by the old constant.
  test "today's rent-exempt minimum is queried, and kept apart from the funded balance" do
    body = page

    pd_space = body[/data-test="contract-pd-rent-min-line"[^>]*data-space="(\d+)"/, 1].to_i
    pd_min = int(body[%r{data-test="contract-pd-rent-min"[^>]*>\s*([\d,]+)}m, 1].to_s)
    buffer_min = int(body[%r{data-test="contract-buffer-min"[^>]*>\s*([\d,]+)}m, 1].to_s)
    program_min = int(body[%r{data-test="contract-program-acct-min"[^>]*>\s*([\d,]+)}m, 1].to_s)
    tx_fee = int(body[%r{data-test="contract-tx-fee"[^>]*>\s*([\d,]+)}m, 1].to_s)
    held = int(body[%r{data-test="contract-accounts-balance"[^>]*>\s*([\d,]+)}m, 1].to_s)
    assert [pd_space, pd_min, buffer_min, program_min, tx_fee, held].all?(&:positive?),
      "a rent figure did not render; the comparisons below would prove nothing"

    assert_operator held, :>, pd_min,
      "the funded balance and today's minimum are different facts; showing one number for both is the bug"
    refute_equal (pd_space + 128) * RETIRED_LAMPORTS_PER_BYTE, pd_min,
      "this minimum is the retired #{RETIRED_LAMPORTS_PER_BYTE}-lamports-a-byte constant multiplied out. " \
      "Query it: solana rent #{pd_space}, or getMinimumBalanceForRentExemption."

    # The calculator's SOL totals must be built from the QUERIED minimums.
    cfg = %w[perm float].to_h { |kind| [ "#{kind}_lamports", body[/data-cost-calculator-#{kind}-lamports-value="(\d+)"/, 1].to_i ] }
    assert_equal pd_min + program_min + tx_fee, cfg["perm_lamports"],
      "the permanent total must be the queried minimums plus deploy fees, nothing else"
    assert_equal cfg["perm_lamports"] + buffer_min, cfg["float_lamports"],
      "the deploy float must be that permanent total plus the queried buffer minimum"
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
