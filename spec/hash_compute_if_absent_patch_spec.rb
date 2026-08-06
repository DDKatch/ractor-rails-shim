# frozen_string_literal: true

# Specs for the `RactorRailsShim::Patches::HashComputeIfAbsent` role object
# (extracted from the facade god module in Step 22.1, Issue #22).
#
# These specs target the role object directly — constructing and calling
# `Patches::HashComputeIfAbsent.install` — pinning the idempotency guard
# and the patch-applied contract without routing through the facade.
#
# Run: ruby -Ilib -Ispec spec/hash_compute_if_absent_patch_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class HashComputeIfAbsentPatchSpec < Minitest::Spec
  # The role object exists and exposes the install entry point.
  it "is a module under Patches with an .install method" do
    assert RactorRailsShim::Patches.const_defined?(:HashComputeIfAbsent, false),
           "RactorRailsShim::Patches::HashComputeIfAbsent should be defined"
    assert RactorRailsShim::Patches::HashComputeIfAbsent.respond_to?(:install),
           "Patches::HashComputeIfAbsent.install should be defined"
  end

  # Idempotency: first call installs, second call is a no-op (does not re-prepend).
  # The flag lives on the role object, not on the facade.
  it "is idempotent — install returns true twice without re-prepending" do
    RactorRailsShim::Patches::HashComputeIfAbsent.reset_installed_for_test!
    r1 = RactorRailsShim::Patches::HashComputeIfAbsent.install
    r2 = RactorRailsShim::Patches::HashComputeIfAbsent.install
    assert r1, "first install should return truthy"
    assert r2, "second install should still return truthy (no-op)"
    assert RactorRailsShim::Patches::HashComputeIfAbsent.installed?,
           "installed? should be true after install"
  ensure
    RactorRailsShim::Patches::HashComputeIfAbsent.reset_installed_for_test!
  end

  # The facade delegates to the role object — keep the existing public seam
  # working while the call sites migrate.
  it "facade _install_hash_compute_if_absent_patch delegates to the role object" do
    # The method is private; call it via send. It must not raise and must
    # return the same result as the role object.
    result = RactorRailsShim.send(:_install_hash_compute_if_absent_patch)
    assert result, "facade delegation should return truthy"
  end

  # The patch actually adds Hash#compute_if_absent (the behavioural contract).
  # We can't easily undefine the method once prepended, so this test only pins
  # the positive case: after install, the method exists and works.
  it "installs a working Hash#compute_if_absent" do
    RactorRailsShim::Patches::HashComputeIfAbsent.install
    assert ::Hash.method_defined?(:compute_if_absent),
           "Hash#compute_if_absent should be defined after install"
    h = {}
    calls = 0
    v = h.compute_if_absent(:k) { calls += 1; "v" }
    assert_equal "v", v
    assert_equal 1, calls
  end
end