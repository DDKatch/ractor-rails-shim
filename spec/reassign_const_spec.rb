# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the centralized _reassign_shareable_const helper that replaces the
# repeated $VERBOSE-suppressed const_set pattern. The old pattern inlined
#   verbose, $VERBOSE = $VERBOSE, nil
#   begin; const_set(:FOO, val); ensure; $VERBOSE = verbose; end
# at every site that rebuilt a "constant" with a new shareable value. The
# helper makes the mutation point explicit and drops the repeated dance.
class ReassignShareableConstSpec < Minitest::Spec
  it "reassigns a constant with the new value, silencing the 'already initialized' warning" do
    # SHAREABLE_FALLBACK starts as a frozen shareable Hash; _reassign should
    # swap in a new frozen shareable Hash without warning.
    old = RactorRailsShim::SHAREABLE_FALLBACK
    new_val = Ractor.make_shareable({ test_key: :test_val }.freeze)
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, new_val)
    assert_equal :test_val, RactorRailsShim::SHAREABLE_FALLBACK[:test_key]
    assert RactorRailsShim::SHAREABLE_FALLBACK.frozen?
    assert Ractor.shareable?(RactorRailsShim::SHAREABLE_FALLBACK)
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, old) if old
  end

  it "does not raise on first assignment (constant already defined with default)" do
    # The constant is already defined (as the empty shareable Hash from
    # core.rb); reassigning should be a normal operation, not an error.
    old = RactorRailsShim::SHAREABLE_MATTR_DEFAULTS
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, Ractor.make_shareable({}.freeze))
    assert RactorRailsShim::SHAREABLE_MATTR_DEFAULTS.frozen?
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, old) if old
  end

  it "works for any constant on RactorRailsShim" do
    # Define a throwaway constant, then reassign it via the helper.
    RactorRailsShim.const_set(:RRS_TEST_CONST, Ractor.make_shareable({}.freeze))
    old = RactorRailsShim::RRS_TEST_CONST
    new_val = Ractor.make_shareable({ replaced: true }.freeze)
    RactorRailsShim._reassign_shareable_const(:RRS_TEST_CONST, new_val)
    assert_equal true, RactorRailsShim::RRS_TEST_CONST[:replaced]
  ensure
    RactorRailsShim.send(:remove_const, :RRS_TEST_CONST) if defined?(RactorRailsShim::RRS_TEST_CONST)
  end
end