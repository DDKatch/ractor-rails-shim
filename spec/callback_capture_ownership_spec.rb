# frozen_string_literal: true

require "minitest/autorun"
require "set"
require "active_support/isolated_execution_state"
require "active_support/callbacks"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the Issue #36a contract: CallbackCapture OWNS its declared_callbacks
# table as a class instance variable, NOT on the RactorRailsShim facade
# singleton. The role's state is no longer split across two objects.
class CallbackCaptureOwnershipSpec < Minitest::Spec
  CC = RactorRailsShim::CallbackCapture

  def reset_table
    CC.remove_instance_variable(:@declared_callbacks) if CC.instance_variable_defined?(:@declared_callbacks)
  end

  it "record_declared_callback writes to CallbackCapture's own table, not the facade" do
    reset_table
    # The facade should NOT hold the table after the call.
    refute RactorRailsShim.instance_variable_defined?(:@declared_callbacks),
           "facade must not hold @declared_callbacks (Issue #36a)"
    CC.record_declared_callback(99901, :before, :set_post, [:index], nil)
    # The table lives on CallbackCapture now.
    assert CC.instance_variable_defined?(:@declared_callbacks),
           "CallbackCapture should own @declared_callbacks"
    table = CC.instance_variable_get(:@declared_callbacks)
    assert_kind_of Hash, table
    assert_includes table.keys, 99901
    # The facade still does NOT hold it.
    refute RactorRailsShim.instance_variable_defined?(:@declared_callbacks),
           "facade must not hold @declared_callbacks after record (Issue #36a)"
  ensure
    reset_table
  end

  it "freeze_declared_callbacks! reads from CallbackCapture's own table" do
    reset_table
    CC.record_declared_callback(99902, :after, :audit, nil, [:destroy])
    CC.freeze_declared_callbacks!
    assert defined?(RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS), "constant should be defined"
    val = RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS
    assert Ractor.shareable?(val)
    assert val.frozen?
    assert_includes val.keys, 99902
  ensure
    reset_table
  end

  it "reset_declared_callbacks! clears the role's own table" do
    reset_table
    CC.record_declared_callback(99903, :before, :check, nil, nil)
    assert CC.instance_variable_defined?(:@declared_callbacks)
    CC.reset_declared_callbacks!
    refute CC.instance_variable_defined?(:@declared_callbacks)
  ensure
    reset_table
  end
end