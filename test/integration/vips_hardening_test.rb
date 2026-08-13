# frozen_string_literal: true

require "test_helper"

# Guards the BEHAVIOURAL half of Active Storage's libvips hardening: that a booted
# process actually REFUSES libvips' untrusted loaders, rather than merely having
# had the chance to. test/lib/vips_dependency_test.rb guards the dependency graph
# that makes this possible; this file crosses the boundary into the real libvips C
# library and checks the control is live.
#
# WHERE THIS ACTUALLY RUNS. libvips is a system library, not a gem, and a
# developer Mac usually does not have it — so ActiveStorage::VIPS_AVAILABLE is
# false there and the block_untrusted assertions below cannot run. They DO run in
# CI: .github/workflows/ci.yml installs libvips in the test job — and if that ever
# stops being true, require_libvips! FAILS there rather than skipping, so the tier
# cannot go uncollected behind a green check. Read a skip below as "this machine
# cannot answer", never as "this passed".
#
# WHY THERE IS A CONTROL COLUMN. libvips reports a blocked loader with exactly the
# same error it reports for a format it was never built to read
# ("VipsForeignLoad: buffer is not in a known format" — measured, not assumed). So
# "loading a BMP raises Vips::Error" is on its own worthless: a libvips compiled
# without its magick delegate satisfies it while completely unhardened. The second
# column — the identical buffer, the same process, the block lifted — is what
# separates the two. Do not delete it to make this file shorter.
class VipsHardeningTest < ActiveSupport::TestCase
  # A minimal 1x1 24-bit BMP, hand-built. It has to be hand-built: libvips has no
  # bmpsave, so libvips cannot produce its own probe. BMP is read through
  # magickload, one of the loaders libvips flags UNTRUSTED, which is what makes it
  # the smallest sample that can tell a hardened process from an unhardened one.
  MINIMAL_BMP = begin
    pixel  = [ 0x00, 0x00, 0xFF, 0x00 ].pack("C4") # one BGR pixel + row padding to 4 bytes
    header = [ 40, 1, 1, 1, 24, 0, pixel.bytesize, 2835, 2835, 0, 0 ].pack("Vl<l<vvVVl<l<VV")
    file   = [ "BM", 14 + header.bytesize + pixel.bytesize, 0, 0, 14 + header.bytesize ].pack("a2VvvV")
    (file + header + pixel).freeze
  end

  # The everyday web formats that must go on loading once libvips is hardened.
  # block_untrusted is meant to cost nothing here — it withdraws the fringe
  # loaders (magickload and friends), not the ones real uploads arrive in.
  TRUSTED_FORMATS = %w[.png .jpg .webp].freeze

  NO_LIBVIPS = "libvips (the C library) is not installed here, so block_untrusted " \
               "cannot be exercised. CI installs it; this is not a pass."

  # Skipping is honest on a developer Mac. In CI it is NOT: .github/workflows/ci.yml
  # installs libvips in the test job, so an unavailable Vips there does not mean
  # "cannot check" — it means this tier stopped being collected, while the run still
  # reports green. That is precisely how the e2e lane rotted unnoticed (see the
  # header of config/feature_shapes.yml in mcritchie-studio). Fail loudly there, so
  # the guard cannot quietly decay into decoration — the same failure mode this
  # whole task exists to prevent, one level up.
  def require_libvips!
    return if ActiveStorage::VIPS_AVAILABLE

    if ENV["CI"].present?
      flunk <<~MESSAGE.squish
        libvips is unavailable in CI, so none of the hardening assertions below ran —
        yet this job would otherwise report green. CI installs libvips in its test
        job; restore that install rather than deleting this check.
      MESSAGE
    end

    skip NO_LIBVIPS
  end

  test "the ruby-vips gem is in the bundle even where libvips itself is absent" do
    # Deliberately unconditional. This is the assertion that keeps the file honest
    # on a machine without libvips: activating a gem needs no C library, so even a
    # Mac that cannot exercise the hardening can still prove the gem never fell out
    # of the dependency graph — the regression this whole task exists to prevent.
    assert_nothing_raised { gem "ruby-vips" }
  end

  test "untrusted libvips loaders are blocked at boot, proven against an unblocked control" do
    require_libvips!

    assert Vips.respond_to?(:block_untrusted), <<~MESSAGE.squish
      This libvips/ruby-vips pair cannot disable untrusted loaders at all. Active
      Storage raises on this condition at boot, so reaching it from inside a test
      means the guard in active_storage/vips.rb has been bypassed.
    MESSAGE

    # HARDENED — the state active_storage/vips.rb leaves every booted process in.
    # Asserted before anything in this file touches the flag, so it reflects boot.
    assert_raises Vips::Error, "an untrusted loader read a BMP: block_untrusted is NOT active" do
      Vips::Image.new_from_buffer(MINIMAL_BMP, "").avg
    end

    # THE CONTROL COLUMN. Succeeds only if the loader was present all along and the
    # hardening is what refused it above.
    control_loads = begin
      Vips.block_untrusted(false)
      Vips::Image.new_from_buffer(MINIMAL_BMP, "").avg
      true
    rescue Vips::Error
      false
    ensure
      Vips.block_untrusted(true)
    end

    assert control_loads, <<~MESSAGE.squish
      Control column failed: this libvips cannot read a BMP even with block_untrusted
      lifted, so the blocked-BMP assertion above proves nothing about the hardening.
      Do not weaken that assertion to make this green — the probe needs a loader this
      libvips actually has and actually flags untrusted.
    MESSAGE
  end

  test "the everyday image formats are unaffected by the hardening" do
    require_libvips!

    sample = Vips::Image.black(8, 8).bandjoin([ 0, 0 ]).copy(interpretation: :srgb).cast(:uchar)

    TRUSTED_FORMATS.each do |extension|
      buffer = sample.write_to_buffer(extension)

      assert_kind_of Numeric, Vips::Image.new_from_buffer(buffer, "").avg, <<~MESSAGE.squish
        Hardening libvips broke #{extension}, an everyday upload format. The block is
        meant to cost nothing on the trusted loaders, so this is a real regression:
        the answer is to narrow what gets blocked, never to stop blocking.
      MESSAGE
    end
  end
end
