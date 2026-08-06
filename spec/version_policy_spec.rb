# frozen_string_literal: true

# Specs for the extracted VersionPolicy concern: the policy switch
# (:warn/:strict/:off), the patch-version registry (PATCH_VERSIONS),
# _register_patch / applicable_patches, and _version_mismatch.
#
# VersionPolicy owns the *policy* + *registry*; version *detection* stays in
# RactorRailsShim::Version. This spec asserts VersionPolicy is independently
# specable — i.e. the behaviour is reachable through the VersionPolicy module
# itself, not only through the RactorRailsShim singleton facade.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class VersionPolicySpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # The module exists and is namespaced under RactorRailsShim.
  it "RactorRailsShim::VersionPolicy is a Module" do
    assert_kind_of Module, RactorRailsShim::VersionPolicy
  end

  it "VersionPolicy::UnsupportedVersionError is defined" do
    assert defined?(RactorRailsShim::VersionPolicy::UnsupportedVersionError)
    assert_kind_of Class, RactorRailsShim::VersionPolicy::UnsupportedVersionError
    assert RactorRailsShim::VersionPolicy::UnsupportedVersionError.ancestors.include?(StandardError)
  end

  it "VersionPolicy::PATCH_VERSIONS is a mutable Hash (the registry)" do
    assert_kind_of Hash, RactorRailsShim::VersionPolicy::PATCH_VERSIONS
  end

  # --- Policy switch ---

  it "VersionPolicy.policy defaults to :warn" do
    assert_equal :warn, RactorRailsShim::VersionPolicy.policy
  ensure
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.policy= accepts :strict / :off / :warn" do
    RactorRailsShim::VersionPolicy.policy = :off
    assert_equal :off, RactorRailsShim::VersionPolicy.policy
    RactorRailsShim::VersionPolicy.policy = :strict
    assert_equal :strict, RactorRailsShim::VersionPolicy.policy
  ensure
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.mismatch :off is silent" do
    RactorRailsShim::VersionPolicy.policy = :off
    out, _ = capture_io { RactorRailsShim::VersionPolicy.mismatch("silent") }
    assert_empty out
  ensure
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.mismatch :strict raises UnsupportedVersionError" do
    RactorRailsShim::VersionPolicy.policy = :strict
    assert_raises(RactorRailsShim::VersionPolicy::UnsupportedVersionError) do
      RactorRailsShim::VersionPolicy.mismatch("fatal")
    end
  ensure
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.mismatch :warn emits to stderr" do
    RactorRailsShim::VersionPolicy.policy = :warn
    out, err = capture_io { RactorRailsShim::VersionPolicy.mismatch("warn me") }
    assert_match(/warn me/, out + err)
  end

  # --- Registry ---

  it "VersionPolicy.register is idempotent and dedupes segments" do
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.clear
    RactorRailsShim::VersionPolicy.register(:dedup, "8.1")
    RactorRailsShim::VersionPolicy.register(:dedup, "8.1")
    RactorRailsShim::VersionPolicy.register(:dedup, "8.2")
    assert_equal ["8.1", "8.2"].sort, RactorRailsShim::VersionPolicy::PATCH_VERSIONS[:dedup].sort
  end

  it "VersionPolicy.applicable splits applied vs skipped by runtime segment" do
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.clear
    RactorRailsShim::VersionPolicy.register(:sample, "8.1")
    # Rails not loaded → seg nil → all applied, none skipped.
    report = RactorRailsShim::VersionPolicy.applicable
    assert_includes report[:applied], :sample
    assert_empty report[:skipped]
  end

  # --- Facade delegation (RactorRailsShim keeps its public surface) ---

  it "RactorRailsShim.version_policy delegates to VersionPolicy.policy" do
    RactorRailsShim::VersionPolicy.policy = :off
    assert_equal :off, RactorRailsShim.version_policy
  ensure
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "RactorRailsShim.version_policy= delegates to VersionPolicy.policy=" do
    RactorRailsShim.version_policy = :strict
    assert_equal :strict, RactorRailsShim::VersionPolicy.policy
  ensure
    RactorRailsShim.version_policy = :warn
  end

  it "RactorRailsShim._register_patch delegates to VersionPolicy.register" do
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.clear
    RactorRailsShim._register_patch(:via_facade, "8.1")
    assert_equal ["8.1"], RactorRailsShim::VersionPolicy::PATCH_VERSIONS[:via_facade]
  end

  it "RactorRailsShim.applicable_patches delegates to VersionPolicy.applicable" do
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.clear
    RactorRailsShim._register_patch(:facade_applicable, "8.1")
    report = RactorRailsShim.applicable_patches
    assert_includes report[:applied], :facade_applicable
  end

  it "RactorRailsShim::UnsupportedVersionError is still defined (alias)" do
    # Existing public API: errors are catchable as RactorRailsShim::UnsupportedVersionError.
    assert defined?(RactorRailsShim::UnsupportedVersionError)
    assert_equal RactorRailsShim::VersionPolicy::UnsupportedVersionError,
                 RactorRailsShim::UnsupportedVersionError
  end

  # --- check_version_support (Issue #46) ---

  it "VersionPolicy.check_version_support warns when Ruby is unsupported" do
    RactorRailsShim::VersionPolicy.policy = :warn
    original = RactorRailsShim::Version.method(:supported_ruby?)
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { false }
    out, err = capture_io { RactorRailsShim::VersionPolicy.check_version_support }
    assert_match(/Ruby/, out + err)
  ensure
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?, original)
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.check_version_support warns when Rails is unsupported" do
    RactorRailsShim::VersionPolicy.policy = :warn
    original_ruby = RactorRailsShim::Version.method(:supported_ruby?)
    original_rails = RactorRailsShim::Version.method(:supported_rails?)
    original_rails_version = RactorRailsShim::Version.method(:rails)
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { true }
    RactorRailsShim::Version.define_singleton_method(:supported_rails?) { false }
    # Stub rails to return a non-nil version so the check actually runs.
    RactorRailsShim::Version.define_singleton_method(:rails) { Gem::Version.new("99.0") }
    out, err = capture_io { RactorRailsShim::VersionPolicy.check_version_support }
    assert_match(/Rails/, out + err)
  ensure
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?, original_ruby)
    RactorRailsShim::Version.define_singleton_method(:supported_rails?, original_rails)
    RactorRailsShim::Version.define_singleton_method(:rails, original_rails_version)
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.check_version_support is silent when both versions are supported" do
    RactorRailsShim::VersionPolicy.policy = :warn
    original_ruby = RactorRailsShim::Version.method(:supported_ruby?)
    original_rails = RactorRailsShim::Version.method(:supported_rails?)
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { true }
    RactorRailsShim::Version.define_singleton_method(:supported_rails?) { true }
    out, err = capture_io { RactorRailsShim::VersionPolicy.check_version_support }
    assert_empty out
    assert_empty err
  ensure
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?, original_ruby)
    RactorRailsShim::Version.define_singleton_method(:supported_rails?, original_rails)
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "VersionPolicy.check_version_support raises under :strict policy" do
    RactorRailsShim::VersionPolicy.policy = :strict
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { false }
    assert_raises(RactorRailsShim::VersionPolicy::UnsupportedVersionError) do
      RactorRailsShim::VersionPolicy.check_version_support
    end
  ensure
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { true }
    RactorRailsShim::VersionPolicy.policy = :warn
  end

  it "RactorRailsShim._check_version_support delegates to VersionPolicy.check_version_support" do
    RactorRailsShim::VersionPolicy.policy = :off
    # With :off policy and both versions supported, should be silent.
    original_ruby = RactorRailsShim::Version.method(:supported_ruby?)
    original_rails = RactorRailsShim::Version.method(:supported_rails?)
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?) { true }
    RactorRailsShim::Version.define_singleton_method(:supported_rails?) { true }
    out, _ = capture_io { RactorRailsShim._check_version_support }
    assert_empty out
  ensure
    RactorRailsShim::Version.define_singleton_method(:supported_ruby?, original_ruby)
    RactorRailsShim::Version.define_singleton_method(:supported_rails?, original_rails)
    RactorRailsShim::VersionPolicy.policy = :warn
  end
end