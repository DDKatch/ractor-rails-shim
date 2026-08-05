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
end
