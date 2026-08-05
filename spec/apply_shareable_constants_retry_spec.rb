# frozen_string_literal: true

# Regression spec for the _apply_shareable_constants! done-flag bug.
#
# _apply_shareable_constants! sets @shareable_constants_done = true after the
# first run, even when some registered constants didn't exist yet (returned
# false from make_constant_shareable). A later call (from make_app_shareable!
# or prepare_for_ractors!) short-circuits on the flag and never retries the
# now-loadable constants — workers then hit IsolationError on the unshareable
# constant.
#
# The fix: only set the done flag when every registered constant was made
# shareable (or already was). If any returned false (constant doesn't exist
# yet), leave the flag unset so the next call retries.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ApplyShareableConstantsRetrySpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  def setup
    super
    # Save and clear: clean slate for each test.
    @saved_constants = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    @saved_flag = RactorRailsShim.instance_variable_get(:@shareable_constants_done)
    RactorRailsShim::SHAREABLE_CONSTANTS.replace([])
    RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if
      RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
  end

  def teardown
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(@saved_constants)
    if @saved_flag.nil?
      RactorRailsShim.remove_instance_variable(:@shareable_constants_done) if
        RactorRailsShim.instance_variable_defined?(:@shareable_constants_done)
    else
      RactorRailsShim.instance_variable_set(:@shareable_constants_done, @saved_flag)
    end
    super
  end

  it "does NOT set the done flag when a registered constant is undefined" do
    # Register a constant path that doesn't exist. make_constant_shareable
    # returns false (constant doesn't exist yet), so _apply_shareable_constants!
    # should leave @shareable_constants_done unset to allow a later retry.
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["ShimProbe::UNDEFINED_CONST"])
    refute defined?(ShimProbe), "setup: ShimProbe should not exist"

    RactorRailsShim.send(:_apply_shareable_constants!)

    refute RactorRailsShim.instance_variable_get(:@shareable_constants_done),
      "done flag should NOT be set when a registered constant is undefined " \
      "(so a later call can retry once the constant loads)"
  end

  it "sets the done flag when every registered constant is made shareable" do
    # Register a constant that DOES exist. _apply_shareable_constants! makes
    # it shareable and sets the flag.
    mod = Module.new
    Object.const_set(:ShimProbeOk, mod)
    mod.const_set(:SHAREABLE_VAL, ["a"].freeze)

    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["ShimProbeOk::SHAREABLE_VAL"])
    RactorRailsShim.send(:_apply_shareable_constants!)

    assert RactorRailsShim.instance_variable_get(:@shareable_constants_done),
      "done flag should be set when all registered constants are resolved"
  ensure
    Object.send(:remove_const, :ShimProbeOk) if defined?(ShimProbeOk)
  end

  it "retries undefined constants on a subsequent call (flag stayed unset)" do
    # First call: constant undefined → flag stays unset.
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["ShimProbeRetry::VAL"])
    refute defined?(ShimProbeRetry), "setup: ShimProbeRetry should not exist"

    RactorRailsShim.send(:_apply_shareable_constants!)
    refute RactorRailsShim.instance_variable_defined?(:@shareable_constants_done) &&
          RactorRailsShim.instance_variable_get(:@shareable_constants_done)

    # Now define the constant and call again → it should be made shareable
    # and the flag set.
    mod = Module.new
    Object.const_set(:ShimProbeRetry, mod)
    mod.const_set(:VAL, ["b"]) # mutable, unshareable

    RactorRailsShim.send(:_apply_shareable_constants!)

    assert Ractor.shareable?(ShimProbeRetry::VAL),
      "second call should have made the now-defined constant shareable"
    assert RactorRailsShim.instance_variable_get(:@shareable_constants_done),
      "done flag should be set after the retry resolves all constants"
  ensure
    Object.send(:remove_const, :ShimProbeRetry) if defined?(ShimProbeRetry)
  end

  it "is idempotent: a second call with the flag set is a no-op" do
    # Once the flag is set (all constants resolved), a second call is a no-op.
    mod = Module.new
    Object.const_set(:ShimProbeIdem, mod)
    mod.const_set(:VAL, ["c"].freeze)

    RactorRailsShim::SHAREABLE_CONSTANTS.replace(["ShimProbeIdem::VAL"])
    RactorRailsShim.send(:_apply_shareable_constants!)
    assert RactorRailsShim.instance_variable_get(:@shareable_constants_done)

    # Second call should not raise and should not re-process (flag already set).
    RactorRailsShim.send(:_apply_shareable_constants!)
    assert RactorRailsShim.instance_variable_get(:@shareable_constants_done)
  ensure
    Object.send(:remove_const, :ShimProbeIdem) if defined?(ShimProbeIdem)
  end
end