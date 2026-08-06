# frozen_string_literal: true

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the Issue #37 contract: VersionPolicy::Strategy replaces the two
# duplicated `case policy when :strict/:off/:warn` switches (in
# VersionPolicy.mismatch and CallbackCapture.read_ivar_or_warn) with three
# strategy modules, each implementing mismatch(message) and
# missing_ivar(obj, ivar, label, funnel:). The case branches disappear.
class VersionPolicyStrategySpec < Minitest::Spec
  VP = RactorRailsShim::VersionPolicy

  def reset_policy
    VP.policy = :warn
  end

  # --- Strategy modules exist ---

  it "VersionPolicy::Strategy is a Module" do
    assert_kind_of Module, VP::Strategy
  end

  it "VersionPolicy::Strategy::Strict is a Module" do
    assert_kind_of Module, VP::Strategy::Strict
  end

  it "VersionPolicy::Strategy::Off is a Module" do
    assert_kind_of Module, VP::Strategy::Off
  end

  it "VersionPolicy::Strategy::Warn is a Module" do
    assert_kind_of Module, VP::Strategy::Warn
  end

  # --- strategy resolves from policy ---

  it "VersionPolicy.strategy returns Strict when policy is :strict" do
    VP.policy = :strict
    assert_same VP::Strategy::Strict, VP.strategy
  ensure
    reset_policy
  end

  it "VersionPolicy.strategy returns Off when policy is :off" do
    VP.policy = :off
    assert_same VP::Strategy::Off, VP.strategy
  ensure
    reset_policy
  end

  it "VersionPolicy.strategy returns Warn when policy is :warn" do
    VP.policy = :warn
    assert_same VP::Strategy::Warn, VP.strategy
  ensure
    reset_policy
  end

  # --- mismatch via strategy (no case branch in VersionPolicy.mismatch) ---

  it "Strategy::Strict.mismatch raises UnsupportedVersionError" do
    assert_raises(VP::UnsupportedVersionError) do
      VP::Strategy::Strict.mismatch("fatal")
    end
  end

  it "Strategy::Off.mismatch is silent" do
    out, _ = capture_io { VP::Strategy::Off.mismatch("silent") }
    assert_empty out
  end

  it "Strategy::Warn.mismatch emits to stderr" do
    out, err = capture_io { VP::Strategy::Warn.mismatch("warn me") }
    assert_match(/warn me/, out + err)
  end

  # --- missing_ivar via strategy (no case branch in CallbackCapture.read_ivar_or_warn) ---

  it "Strategy::Strict.missing_ivar raises UnsupportedVersionError" do
    obj = Object.new
    assert_raises(VP::UnsupportedVersionError) do
      VP::Strategy::Strict.missing_ivar(obj, :@missing, "test label", funnel: nil)
    end
  end

  it "Strategy::Off.missing_ivar returns nil silently" do
    obj = Object.new
    assert_nil VP::Strategy::Off.missing_ivar(obj, :@missing, "test label", funnel: nil)
  end

  it "Strategy::Warn.missing_ivar returns nil and warns via funnel when debug? is on" do
    obj = Object.new
    warned = []
    funnel = ->(label) { warned << label }
    RactorRailsShim.debug = true
    VP::Strategy::Warn.missing_ivar(obj, :@missing, "test label", funnel: funnel)
    assert_includes warned, "test label"
  ensure
    RactorRailsShim.debug = false
  end

  it "Strategy::Warn.missing_ivar returns nil silently when debug? is off" do
    obj = Object.new
    warned = []
    funnel = ->(label) { warned << label }
    RactorRailsShim.debug = false
    assert_nil VP::Strategy::Warn.missing_ivar(obj, :@missing, "test label", funnel: funnel)
    assert_empty warned
  end

  # --- VersionPolicy.mismatch delegates to strategy (no case) ---

  it "VersionPolicy.mismatch delegates to the strategy module" do
    VP.policy = :strict
    assert_raises(VP::UnsupportedVersionError) { VP.mismatch("via strategy") }
    VP.policy = :off
    out, _ = capture_io { VP.mismatch("via strategy") }
    assert_empty out
  ensure
    reset_policy
  end
end