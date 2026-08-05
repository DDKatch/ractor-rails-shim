# frozen_string_literal: true

# Specs for `RactorRailsShim.capture_app_constants!!` — the main-Ractor routine
# that walks the app's Zeitwerk loaders, captures every loaded constant's
# name → object mapping, and returns a frozen shareable map for worker
# Ractors to rebind.
#
# These specs verify the defensive guards around `Rails.autoloaders`:
#
#   * nil / not-responding-to-:autoloaders → returns empty frozen map
#   * classic-loader / null autoloaders object (no `main`/`once`, no `each`)
#     → returns empty frozen map instead of NoMethodError
#   * a loader without `all_expected_cpaths` (not Zeitwerk) → skipped
#   * a well-formed Zeitwerk autoloaders → captures shareable constants
#
# Run: ruby -Ilib -Ispec spec/capture_app_constants_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class CaptureAppConstantsSpec < Minitest::Spec
  # Fakes for the Rails autoloaders surface. We stub `::Rails` for the
  # duration of each test, SAVING AND RESTORING the original constant so we
  # don't clobber a `Rails` module another spec file defined at load time
  # (e.g. check_spec.rb defines `module Rails::CheckSpecFixture`).
  def with_rails(autoloaders_value)
    saved = defined?(::Rails) ? ::Rails : nil
    Object.send(:remove_const, :Rails) if defined?(::Rails)
    fake_rails = Module.new
    fake_rails.define_singleton_method(:autoloaders) { autoloaders_value } unless autoloaders_value.nil?
    Object.const_set(:Rails, fake_rails)
    yield
  ensure
    Object.send(:remove_const, :Rails) if defined?(::Rails)
    Object.const_set(:Rails, saved) if saved
  end

  it "returns an empty frozen map when Rails is not defined" do
    saved = defined?(::Rails) ? ::Rails : nil
    Object.send(:remove_const, :Rails) if defined?(::Rails)
    map = RactorRailsShim.capture_app_constants!
    assert_equal({}, map)
    assert map.frozen?
  ensure
    Object.const_set(:Rails, saved) if saved
  end

  it "returns an empty frozen map when Rails doesn't respond to :autoloaders" do
    fake = Module.new
    with_rails(nil) do
      map = RactorRailsShim.capture_app_constants!
      assert_equal({}, map)
      assert map.frozen?
    end
  end

  it "returns an empty frozen map for a non-Zeitwerk autoloaders object (no main/once/each)" do
    # Simulates classic-loader mode or config.autoloaders = false returning
    # a null object. Pre-fix, this would NoMethodError on `autoloaders.main`.
    null_autoloaders = Object.new
    with_rails(null_autoloaders) do
      map = RactorRailsShim.capture_app_constants!
      assert_equal({}, map)
      assert map.frozen?
    end
  end

  it "skips loaders that don't expose all_expected_cpaths (not Zeitwerk)" do
    not_zeitwerk = Object.new
    zeitwerk_like = Object.new
    zeitwerk_like.define_singleton_method(:all_expected_cpaths) do
      { "ShimCaptureProbe" => "ShimCaptureProbe" }
    end
    autoloaders = Object.new
    autoloaders.define_singleton_method(:main) { not_zeitwerk }
    autoloaders.define_singleton_method(:once) { zeitwerk_like }

    # Define a shareable probe constant so the capture records it.
    Object.const_set(:ShimCaptureProbe, "shareable-value".freeze)

    with_rails(autoloaders) do
      map = RactorRailsShim.capture_app_constants!
      assert_equal({ "ShimCaptureProbe" => "shareable-value" }, map)
    end
  ensure
    Object.send(:remove_const, :ShimCaptureProbe) if defined?(ShimCaptureProbe)
  end

  it "captures constants from a Zeitwerk-style autoloaders object" do
    loader = Object.new
    loader.define_singleton_method(:all_expected_cpaths) do
      { "ShimCaptureA" => "ShimCaptureA", "ShimCaptureB" => "ShimCaptureB" }
    end
    autoloaders = Object.new
    autoloaders.define_singleton_method(:main) { loader }
    autoloaders.define_singleton_method(:once) { nil }

    Object.const_set(:ShimCaptureA, "a".freeze)
    Object.const_set(:ShimCaptureB, "b".freeze)

    with_rails(autoloaders) do
      map = RactorRailsShim.capture_app_constants!
      assert_equal "a", map["ShimCaptureA"]
      assert_equal "b", map["ShimCaptureB"]
      assert map.frozen?
    end
  ensure
    Object.send(:remove_const, :ShimCaptureA) if defined?(ShimCaptureA)
    Object.send(:remove_const, :ShimCaptureB) if defined?(ShimCaptureB)
  end
end