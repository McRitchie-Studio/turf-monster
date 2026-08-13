# frozen_string_literal: true

require "test_helper"

# Guards the DEPENDENCY-GRAPH half of Active Storage's libvips hardening.
#
# Rails hardens libvips against untrusted content in
# activestorage/lib/active_storage/vips.rb: it requires ruby-vips, and ONLY if
# that require succeeds does it call Vips.block_untrusted(true). When the require
# raises, the file swallows the error, sets ActiveStorage::VIPS_AVAILABLE = false,
# and the hardening never runs. Nothing warns. The app boots clean and goes on
# handling images through mini_magick, so the loss leaves no trace to notice.
#
# That makes the hardening exactly as durable as ruby-vips' place in this app's
# dependency graph — and that place used to be on loan. image_processing 1.14.0
# declares `ruby-vips (>= 2.0.17, < 3)` as a runtime dependency; image_processing
# 2.0.x declares NONE. An app that reaches vips only THROUGH image_processing
# therefore loses the gem outright the moment it takes the 2.0 bump.
#
# WHY THIS ASSERTS DIRECTNESS AND NOT PRESENCE: measured on this repo before the
# fix, ruby-vips was ALREADY in Gemfile.lock — transitively, via image_processing.
# So a "ruby-vips appears in the lockfile" assertion was GREEN in precisely the
# state this guard exists to catch, and would have gone on being green until the
# day it mattered. Directness is the property that actually bites.
class VipsDependencyTest < ActiveSupport::TestCase
  # Bundler.load reads this app's Gemfile — the DIRECT declarations, and only
  # those. Gems pulled in transitively never appear here, which is the point.
  def direct_dependency
    Bundler.load.dependencies.find { |dependency| dependency.name == "ruby-vips" }
  end

  test "ruby-vips is declared directly, not inherited from image_processing" do
    assert direct_dependency, <<~MESSAGE.squish
      ruby-vips is not a DIRECT dependency in this app's Gemfile. Active Storage
      calls Vips.block_untrusted(true) only when `require "ruby-vips"` succeeds, so
      leaving image_processing to supply the gem means an image_processing 2.0 bump
      (which declares no ruby-vips dependency of its own) drops it from the bundle
      and silently disables the hardening. Declare `gem "ruby-vips"` in the Gemfile.
    MESSAGE
  end

  test "the ruby-vips declaration is in the default group, so production keeps it" do
    dependency = direct_dependency
    assert dependency, "ruby-vips is not declared directly at all — see the directness test above"

    assert_includes dependency.groups, :default, <<~MESSAGE.squish
      ruby-vips is declared, but outside the default group, so a production bundle
      that skips that group would not install it. The hardening would then be active
      in development and test and absent in production — the worst of the three
      outcomes, because the suite stays green while production runs unprotected.
    MESSAGE
  end

  test "the ruby-vips declaration does not make Bundler require it at boot" do
    dependency = direct_dependency
    assert dependency, "ruby-vips is not declared directly at all — see the directness test above"

    assert_equal [], dependency.autorequire, <<~MESSAGE.squish
      ruby-vips is declared WITHOUT `require: false`, so Bundler.require loads it
      during boot. ruby-vips binds the libvips C library at require time, so on any
      machine without libvips — every developer Mac — the app now dies with LoadError
      before Rails starts. CI is structurally blind to this: its test job installs
      libvips, so the break appears only on developer machines. Active Storage does
      its own require inside a rescue; that is the only require this gem needs.
    MESSAGE
  end

  test "the resolved ruby-vips is new enough to disable untrusted loaders" do
    spec = Bundler.locked_gems.specs.find { |locked| locked.name == "ruby-vips" }
    assert spec, "ruby-vips resolved to nothing at all in Gemfile.lock"

    assert Gem::Version.new(spec.version) >= Gem::Version.new("2.2.1"), <<~MESSAGE.squish
      ruby-vips #{spec.version} predates Vips.block_untrusted, which arrived in 2.2.1.
      This is not a silent failure like the others: active_storage/vips.rb raises a
      bare RuntimeError when Vips does not respond to block_untrusted, and
      active_storage/engine.rb rescues LoadError only — so too old a ruby-vips is an
      unrescued crash on boot.
    MESSAGE
  end
end
