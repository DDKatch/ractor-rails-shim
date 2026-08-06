# frozen_string_literal: true

# Specs for ConstReassign (Issue #46 Step 46.2): the $VERBOSE-suppressed
# const_set utility extracted from the facade's _reassign_shareable_const.
# The facade's method calls ConstReassign.call, then updates Registry for
# the four known registries. Role objects inject ConstReassign.method(:call)
# directly via the configure seam.

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class ConstReassignSpec < Minitest::Spec
  CR = RactorRailsShim::ConstReassign

  it "RactorRailsShim::ConstReassign is defined" do
    assert defined?(CR),
           "ConstReassign should be defined"
  end

  it "ConstReassign.call sets the constant on the target module" do
    target = Module.new
    target.const_set(:TEST_CONST, :old_value)
    CR.call(target, :TEST_CONST, :new_value)
    assert_equal :new_value, target.const_get(:TEST_CONST)
  ensure
    target.send(:remove_const, :TEST_CONST) if target.const_defined?(:TEST_CONST)
  end

  it "ConstReassign.call suppresses warnings during const_set" do
    target = Module.new
    target.const_set(:WARN_CONST, :first)
    out, err = capture_io { CR.call(target, :WARN_CONST, :second) }
    assert_empty err
    assert_equal :second, target.const_get(:WARN_CONST)
  ensure
    target.send(:remove_const, :WARN_CONST) if target.const_defined?(:WARN_CONST)
  end

  it "ConstReassign.call restores $VERBOSE after const_set" do
    target = Module.new
    target.const_set(:VERBOSE_CONST, :old)
    original_verbose = $VERBOSE
    CR.call(target, :VERBOSE_CONST, :new)
    assert_equal original_verbose, $VERBOSE
  ensure
    $VERBOSE = original_verbose if defined?(original_verbose)
    target.send(:remove_const, :VERBOSE_CONST) if target.const_defined?(:VERBOSE_CONST)
  end

  it "ConstReassign.call returns the new value" do
    target = Module.new
    result = CR.call(target, :RET_CONST, :returned)
    assert_equal :returned, result
  ensure
    target.send(:remove_const, :RET_CONST) if target.const_defined?(:RET_CONST)
  end

  it "RactorRailsShim._reassign_shareable_const delegates to ConstReassign.call" do
    old = RactorRailsShim::SHAREABLE_FALLBACK
    new_val = Ractor.make_shareable({ reassign_test: true }.freeze)
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, new_val)
    assert_equal true, RactorRailsShim::SHAREABLE_FALLBACK[:reassign_test]
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, old) if old
  end
end
