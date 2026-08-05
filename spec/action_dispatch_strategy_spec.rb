# frozen_string_literal: true

# Specs for the `RactorRailsShim::ActionDispatchStrategy` role object
# (extracted from the facade god module in Step 22.5, Issue #22).
#
# These specs target the role object directly — calling
# `ActionDispatchStrategy.replacement_for(proc_obj)` — pinning the
# SERVE/CALL identity dispatch and the NoOpProc fallback without
# routing through the facade or requiring action_dispatch.
#
# Run: ruby -Ilib -Ispec spec/action_dispatch_strategy_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ActionDispatchStrategySpec < Minitest::Spec
  NoOpProc = RactorRailsShim.singleton_class.const_get(:NoOpProc)
  StrategyServe = RactorRailsShim.singleton_class.const_get(:StrategyServe)
  StrategyCall = RactorRailsShim.singleton_class.const_get(:StrategyCall)

  # The role object exists and exposes the entry point.
  it "is a module under RactorRailsShim with a .replacement_for method" do
    assert RactorRailsShim.const_defined?(:ActionDispatchStrategy, false),
           "RactorRailsShim::ActionDispatchStrategy should be defined"
    assert RactorRailsShim::ActionDispatchStrategy.respond_to?(:replacement_for),
           "ActionDispatchStrategy.replacement_for should be defined"
  end

  # When ActionDispatch::Routing::Mapper::Constraints is not defined,
  # returns NoOpProc (defensive — never mis-route).
  it "returns NoOpProc when Constraints is not defined" do
    # Constraints is not loaded under the shim's own bundle.
    result = RactorRailsShim::ActionDispatchStrategy.replacement_for(->(*) {})
    assert_kind_of NoOpProc, result,
                   "should return NoOpProc when Constraints is undefined"
  end

  # When Constraints IS defined, SERVE -> StrategyServe, CALL -> StrategyCall,
  # unknown -> NoOpProc. We stub Constraints to test the identity dispatch.
  it "returns StrategyServe when the proc is identical to Constraints::SERVE" do
    stub_constraints(:SERVE, :CALL) do |constraints|
      result = RactorRailsShim::ActionDispatchStrategy.replacement_for(constraints::SERVE)
      assert_kind_of StrategyServe, result,
                     "SERVE proc should be replaced with StrategyServe"
    end
  end

  it "returns StrategyCall when the proc is identical to Constraints::CALL" do
    stub_constraints(:SERVE, :CALL) do |constraints|
      result = RactorRailsShim::ActionDispatchStrategy.replacement_for(constraints::CALL)
      assert_kind_of StrategyCall, result,
                     "CALL proc should be replaced with StrategyCall"
    end
  end

  it "returns NoOpProc for an unrelated proc (never mis-routes)" do
    stub_constraints(:SERVE, :CALL) do |constraints|
      fake = ->(*) { :not_a_strategy }
      result = RactorRailsShim::ActionDispatchStrategy.replacement_for(fake)
      assert_kind_of NoOpProc, result,
                     "an unrelated proc should become NoOpProc, not a Strategy"
      refute_kind_of StrategyServe, result
      refute_kind_of StrategyCall, result
    end
  end

  # The facade delegates to the role object.
  it "facade _strategy_replacement_for delegates to the role object" do
    result = RactorRailsShim.send(:_strategy_replacement_for, ->(*) {})
    assert_kind_of NoOpProc, result,
                   "facade delegation should return NoOpProc (no Constraints)"
  end

  private

  # Stub ::ActionDispatch::Routing::Mapper::Constraints with SERVE and CALL
  # constant Proc objects for the duration of the block. Yields the
  # constraints module.
  def stub_constraints(serve_name, call_name)
    # Save and remove any existing Constraints tree.
    saved_ad = nil
    if defined?(::ActionDispatch)
      saved_ad = ::ActionDispatch
      Object.send(:remove_const, :ActionDispatch)
    end
    begin
      ad = Module.new
      routing = Module.new { }
      ad.const_set(:Routing, routing)
      mapper = Module.new
      routing.const_set(:Mapper, mapper)
      constraints = Module.new
      mapper.const_set(:Constraints, constraints)
      serve = ->(app, req) { app.serve req }
      call = ->(app, req) { app.call req.env }
      constraints.const_set(:SERVE, serve)
      constraints.const_set(:CALL, call)
      Object.const_set(:ActionDispatch, ad)
      yield constraints
    ensure
      Object.send(:remove_const, :ActionDispatch) if defined?(::ActionDispatch) &&
        defined?(ad) && ::ActionDispatch.equal?(ad)
      Object.const_set(:ActionDispatch, saved_ad) if saved_ad
    end
  end
end