# frozen_string_literal: true

# Specs for the `_swallow` debug funnel and `debug?` flag.
#
# The shim's freeze/shareability paths rescue many exceptions silently
# (individual ivars may hold intrinsically unshareable values like Procs).
# Pre-cleanup these were bare `rescue; nil`, so a worker Ractor that later
# crashed on an unshareable value had no traceable cause. The `_swallow`
# funnel centralizes the swallow: silent by default, but emits a labeled
# $stderr line when `RactorRailsShim.debug = true`.
#
# Run: ruby -Ilib -Ispec spec/debug_funnel_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class DebugFunnelSpec < Minitest::Spec
  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it "debug? defaults to false" do
    RactorRailsShim.instance_variable_set(:@debug, nil) # reset
    refute RactorRailsShim.debug?
  end

  it "debug = true is honoured" do
    RactorRailsShim.debug = true
    assert RactorRailsShim.debug?
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow returns the block's value on success" do
    assert_equal 42, RactorRailsShim._swallow("test") { 42 }
  end

  it "_swallow returns nil on exception and is silent by default" do
    RactorRailsShim.debug = false
    out = capture_stderr do
      assert_nil RactorRailsShim._swallow("test") { raise RuntimeError, "boom" }
    end
    assert_empty out, "no stderr output when debug? is false"
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow emits a labeled $stderr line when debug? is true" do
    RactorRailsShim.debug = true
    out = capture_stderr do
      RactorRailsShim._swallow("freeze AR ivar Post@column_defaults") do
        raise RuntimeError, "can't freeze a Proc"
      end
    end
    assert_includes out, "[ractor_rails_shim]"
    assert_includes out, "freeze AR ivar Post@column_defaults"
    assert_includes out, "RuntimeError"
    assert_includes out, "can't freeze a Proc"
  ensure
    RactorRailsShim.debug = false
  end

  it "_swallow truncates long messages so stderr stays readable" do
    RactorRailsShim.debug = true
    long_msg = "x" * 500
    out = capture_stderr do
      RactorRailsShim._swallow("lbl") { raise RuntimeError, long_msg }
    end
    # The line should not contain the full 500-char message.
    refute_includes out, long_msg
    assert_includes out, "x" * 120 # truncated to ~120 chars
  ensure
    RactorRailsShim.debug = false
  end
end