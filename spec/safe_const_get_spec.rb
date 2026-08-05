# frozen_string_literal: true

# Spec for Issue #4: extract a _safe_const_get helper to replace dense
# rescue/& chains like:
#   mod = (Object.const_get(:ActiveSupport) rescue nil)&.const_get(:Messages, false) rescue nil
#   mod = mod&.const_get(:Metadata, false) rescue nil

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class SafeConstGetSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  it "resolves a top-level constant" do
    assert_equal Object, RactorRailsShim._safe_const_get("Object")
  end

  it "resolves a nested constant path" do
    assert_equal ActiveSupport::IsolatedExecutionState,
                 RactorRailsShim._safe_const_get("ActiveSupport::IsolatedExecutionState")
  end

  it "returns nil for a missing top-level constant" do
    assert_nil RactorRailsShim._safe_const_get("NonexistentModule")
  end

  it "returns nil for a missing nested constant" do
    assert_nil RactorRailsShim._safe_const_get("ActiveSupport::NonexistentThing")
  end

  it "returns nil when the parent is missing" do
    assert_nil RactorRailsShim._safe_const_get("Nonexistent::Child::Grandchild")
  end

  it "returns nil when a middle segment is missing" do
    assert_nil RactorRailsShim._safe_const_get("ActiveSupport::Missing::Deep")
  end

  # --- Behavioral equivalence with the removed code ---

  # The original _freeze_messages_constants! used:
  #   (Object.const_get(:ActiveSupport) rescue nil)&.const_get(:Messages, false) rescue nil
  #   mod = mod&.const_get(:Metadata, false) rescue nil
  # The `false` flag means no-inherit (only look in the receiver's own
  # constant table, not ancestors). _safe_const_get with inherit: false
  # must reproduce that exact behavior.

  it "with inherit: false, resolves directly-defined constants" do
    result = RactorRailsShim._safe_const_get("ActiveSupport::IsolatedExecutionState", inherit: false)
    assert_equal ActiveSupport::IsolatedExecutionState, result
  end

  it "with inherit: false, does NOT find constants inherited from ancestors" do
    # A module that includes another module won't find the included module's
    # constants with inherit: false (only looks in own constant table).
    sub = Module.new { const_set(:CHILD, 42) }
    child = Module.new { include sub }
    child.const_set(:MINE, 99)
    assert_equal 99, child.const_get(:MINE, false), "sanity: own constant found"
    assert_raises(NameError) { child.const_get(:CHILD, false) }
    # _safe_const_get with inherit: false should match
    Object.const_set(:InheritTestChild, child) unless Object.const_defined?(:InheritTestChild)
    begin
      assert_nil RactorRailsShim._safe_const_get("InheritTestChild::CHILD", inherit: false),
                 "inherit: false must not resolve inherited constants"
    ensure
      Object.send(:remove_const, :InheritTestChild)
    end
  end

  it "with inherit: true (default), finds constants inherited from ancestors" do
    mod = Module.new
    sub = Module.new { const_set(:CHILD, 42) }
    mod.include(sub)
    child = Module.new { include mod }
    Object.const_set(:InheritTestChild2, child) unless Object.const_defined?(:InheritTestChild2)
    begin
      result = RactorRailsShim._safe_const_get("InheritTestChild2::CHILD")
      assert_equal 42, result,
                   "inherit: true should resolve inherited constants"
    ensure
      Object.send(:remove_const, :InheritTestChild2)
    end
  end
end
