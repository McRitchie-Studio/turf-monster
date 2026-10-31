# frozen_string_literal: true

require "test_helper"

# [unit] Task turf-adopts-type-scale: every Tailwind font size Turf uses lands
# on one of the engine's five roles (app/assets/tailwind/type_scale.css), at the
# multiples Studio::TypeScale::ROLES names; no source sets a pixel size of its
# own; the only off-scale sizes are the named, measured exemptions; and the four
# Studio.type_* settings are the turf brand kit's.
class TurfTypeScaleTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/type_scale.css")
  # Alex McRitchie's ruling of 2026-10-28, sorted the way the hub sorted it.
  EXPECTED = {
    "3xs" => 0.75, "2xs" => 0.75, "xs" => 0.75,
    "sm" => 1, "base" => 1,
    "lg" => 1.5, "xl" => 1.5, "2xl" => 1.5,
    "3xl" => 3, "4xl" => 3,
    "5xl" => 6, "6xl" => 6, "7xl" => 6, "8xl" => 6, "9xl" => 6
  }.freeze
  SIZE_CLASS = /(?<![\w-])text-(3xs|2xs|xs|sm|base|lg|[2-9]?xl)(?![\w-])/
  # The turf kit's settings (the hub's Logos::TypeScale.new(BrandKit.new("turf")).engine_settings).
  TURF_KIT = { type_base: 16, type_dense_base: 14, type_display_weight: 800, type_text_weight: 500 }.freeze

  def mapped
    CSS.read.scan(/--text-([0-9a-z]+): calc\(var\(--type-base, 16px\) \* ([\d.]+)\);/).to_h { |size, n| [size, n.to_f] }
  end

  def sources = Dir[Rails.root.join("app/{views,components,helpers,javascript,services}/**/*.{erb,rb,js}")]

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  test "every Tailwind size maps to its step" do
    assert_equal EXPECTED.transform_values(&:to_f), mapped
  end

  test "the map is @theme inline, so type-dense re-resolves it per element" do
    assert_match(/^@theme inline \{/, CSS.read)
  end

  test "every multiple is one of the engine's roles" do
    roles = Studio::TypeScale::ROLES.map { |_, multiple, _| multiple.to_f }
    assert_empty mapped.values.uniq - roles
    assert_equal roles.sort, mapped.values.uniq.sort, "each role is reached by some size"
  end

  test "every size class in the app is a mapped one" do
    used = sources.flat_map { |path| File.read(path).scan(SIZE_CLASS).flatten }.uniq
    assert_empty used - mapped.keys
  end

  test "no source sets an arbitrary font size" do
    offenders = sources.select { |path| File.read(path).match?(/text-\[[\d.]+(px|rem|em)\]/) }
    assert_empty offenders.map { |path| relative(path) }
  end

  test "the only off-scale sizes are the named, measured exemptions" do
    fixed = CSS.read.scan(/@utility ([\w-]+) \{[^}]*?(?:font-size|--type-base): (\d[\w.]*);/)
    assert_equal [ %w[tile-print-label 10px], %w[tile-print-week 9px], %w[type-mini 12px] ], fixed
    used = sources.select { |path| File.read(path).match?(/\btile-print-(label|week)\b/) }.map { |path| relative(path) }
    assert_equal [ "app/views/contests/_multi_week_team_card.html.erb" ], used,
                 "the tile sizes were measured for the multi-week card's opponent column only"
  end

  test "the map is imported after the engine layer, so it wins" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_operator css.index("@import '../builds/tailwind/studio_engine'"), :<, css.index("@import './type_scale.css'")
  end

  test "the Studio.type_* settings are the turf brand kit's" do
    assert_equal TURF_KIT, TURF_KIT.keys.to_h { |name| [name, Studio.public_send(name)] }
  end
end
