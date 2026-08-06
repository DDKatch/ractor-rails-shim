# frozen_string_literal: true

# Specs for the `Hash#compute_if_absent` patch (core.rb
# `_install_hash_compute_if_absent_patch`).
#
# The shim replaces `Concurrent::Map` instances in the frozen app graph with
# plain `Hash`es (Concurrent::Map is not Ractor-shareable). Rails code calls
# `compute_if_absent` on these caches, so the shim adds a compatible method
# to `Hash`. The specs verify two invariants:
#
#   1. on a MUTABLE Hash, semantics match `Concurrent::Map#compute_if_absent`
#      — including the nil-result case (the key is stored, the block is NOT
#      re-invoked on the next lookup).
#   2. on a FROZEN Hash (the shareable case — workers can't mutate it), the
#      result is routed to per-Ractor IES keyed by the Hash's object_id +
#      the key. Same nil-storing semantics: a nil block result must be
#      cached so the block doesn't re-run on every call.
#
# Pre-fix, the frozen branch used `IES[key] ||= yield`, which diverges from
# `Concurrent::Map` on nil results: a nil block result was never stored, so
# the block re-ran on every subsequent call. The non-frozen branch was
# already correct (uses `key?`).
#
# Run: ruby -Ilib -Ispec spec/compute_if_absent_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Install the patch (the shim doesn't auto-install without Rails).
RactorRailsShim.send(:_install_hash_compute_if_absent_patch)

class ComputeIfAbsentSpec < Minitest::Spec
  it "is defined on Hash after install" do
    assert ::Hash.method_defined?(:compute_if_absent)
  end

  it "mutable Hash: stores the block result and returns it on subsequent lookups" do
    h = {}
    calls = 0
    result = h.compute_if_absent(:k) { calls += 1; "v" }
    assert_equal "v", result
    assert_equal 1, calls, "block should run once"
    assert_equal "v", h.compute_if_absent(:k) { calls += 1; "v" }
    assert_equal 1, calls, "block should not re-run after store"
  end

  it "mutable Hash: stores nil block results (matches Concurrent::Map)" do
    h = {}
    calls = 0
    result = h.compute_if_absent(:k) { calls += 1; nil }
    assert_nil result
    assert_equal 1, calls, "block should run once"
    assert_nil h.compute_if_absent(:k) { calls += 1; nil }
    assert_equal 1, calls, "nil result must be cached — block should NOT re-run"
    assert h.key?(:k), "nil-valued key must be present after compute_if_absent"
  end

  it "frozen Hash: routes to per-Ractor IES and caches results" do
    h = { existing: "present" }.freeze
    calls = 0
    # existing key returns the value without invoking the block
    assert_equal "present", h.compute_if_absent(:existing) { calls += 1; "x" }
    assert_equal 0, calls, "block should not run for an existing key"

    # missing key invokes the block, caches the result in IES
    result = h.compute_if_absent(:missing) { calls += 1; "cached" }
    assert_equal "cached", result
    assert_equal 1, calls
    # second lookup reads from IES, block does NOT re-run
    assert_equal "cached", h.compute_if_absent(:missing) { calls += 1; "other" }
    assert_equal 1, calls, "frozen branch must cache — block should not re-run"
  end

  it "frozen Hash: caches nil block results (matches Concurrent::Map)" do
    h = {}.freeze
    calls = 0
    result = h.compute_if_absent(:nil_key) { calls += 1; nil }
    assert_nil result
    assert_equal 1, calls
    # The bug: ||= skips nil, so the block would re-run. Verify it doesn't.
    assert_nil h.compute_if_absent(:nil_key) { calls += 1; nil }
    assert_equal 1, calls,
      "frozen branch must cache nil results — block re-ran #{calls - 1} extra time(s)"
  end

  it "frozen Hash: per-Hash isolation (two frozen hashes with the same key don't collide)" do
    # Use distinct non-empty frozen hashes — Ruby dedupes frozen empty
    # literals ({}.freeze returns the same object), so the two receivers
    # must carry different content to be distinct objects with different
    # object_ids. The shim's real call sites use populated caches, so this
    # matches production.
    h1 = { a: 1 }.freeze
    h2 = { b: 2 }.freeze
    refute_equal h1.object_id, h2.object_id, "spec setup: receivers must be distinct objects"
    h1.compute_if_absent(:k) { "from-h1" }
    assert_equal "from-h1", h1.compute_if_absent(:k) { "other" }
    # h2's slot for :k is independent (keyed by object_id)
    assert_equal "from-h2", h2.compute_if_absent(:k) { "from-h2" }
    assert_equal "from-h1", h1.compute_if_absent(:k) { "other" }
  end
end