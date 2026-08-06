# frozen_string_literal: true

# Specs for the ActionDispatch strategy-Proc replacement in
# `make_app_shareable!`'s graph traversal (`_replace_one_proc`).
#
# `ActionDispatch::Routing::Mapper::Constraints` stores one of two strategy
# Procs in `@strategy`:
#
#   SERVE = ->(app, req) { app.serve req }   # dispatcher endpoint
#   CALL  = ->(app, req) { app.call req.env } # app endpoint
#
# Both are self-capturing Procs (capture the defining Ractor's binding), so
# they block `Ractor.make_shareable(app)`. The shim replaces them with
# shareable callable stand-ins (`StrategyServe` / `StrategyCall`).
#
# The original implementation distinguished the two by `source_location[1]`
# (the line number), hard-coded to `32`:
#
#   line == 32 ? StrategyServe.new : StrategyCall.new
#
# That line number is fragile — any Rails patch release that shifts the
# constant definitions by even one line silently swaps the two strategies,
# breaking routing (a dispatcher endpoint would be called as
# `app.call(req.env)` instead of `app.serve(req)`).
#
# The fix compares the Proc by IDENTITY against the actual `SERVE` / `CALL`
# constants (the value stored in `@strategy` IS the constant object), which
# is robust against source-line shifts. These specs pin the contract:
#   - SERVE → StrategyServe
#   - CALL  → StrategyCall
#   - any other Proc → NoOpProc (never a mis-routed strategy)
#   - the replacements call the right method on the receiver
#
# Run: ruby -Ilib -Ispec spec/strategy_proc_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# This spec needs ActionDispatch::Routing::Mapper::Constraints (part of
# actionpack). The shim's own bundle has no Rails dep (unit specs run
# standalone), so skip the whole file when action_dispatch isn't loadable.
AD_AVAILABLE = begin
  require "action_dispatch"
  true
rescue LoadError
  false
end

if AD_AVAILABLE
class StrategyProcSpec < Minitest::Spec
  Constraints = ActionDispatch::Routing::Mapper::Constraints
  SERVE = Constraints::SERVE
  CALL  = Constraints::CALL

  StrategyServe = RactorRailsShim.singleton_class.const_get(:StrategyServe)
  StrategyCall  = RactorRailsShim.singleton_class.const_get(:StrategyCall)
  NoOpProc      = RactorRailsShim.singleton_class.const_get(:NoOpProc)

  # A plain container whose ivar the graph traversal can walk. (Struct stores
  # its members in an internal Array, not @-ivars, so the traversal wouldn't
  # reach the wrapped Constraints — use a real class with an attr_reader.)
  class StrategyHolder
    attr_reader :strategy
    def initialize(strategy); @strategy = strategy; end
  end

  # Build a Constraints instance with the given strategy the same way Rails
  # does (pass the constant as `strategy`).
  def build_constraints(strategy)
    app = Object.new
    Constraints.new(app, [], strategy)
  end

  it "SERVE strategy Proc is replaced with a StrategyServe" do
    c = build_constraints(SERVE)
    holder = StrategyHolder.new(c)

    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)

    replaced = c.instance_variable_get(:@strategy)
    assert_kind_of StrategyServe, replaced,
      "SERVE Proc must be replaced with StrategyServe (got #{replaced.class})"
  end

  it "CALL strategy Proc is replaced with a StrategyCall" do
    c = build_constraints(CALL)
    holder = StrategyHolder.new(c)

    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)

    replaced = c.instance_variable_get(:@strategy)
    assert_kind_of StrategyCall, replaced,
      "CALL Proc must be replaced with StrategyCall (got #{replaced.class})"
  end

  it "an unrelated Proc in :@strategy is NOT mis-routed to a Strategy (no fallthrough)" do
    # The original line-based code dispatched ANY Proc in :@strategy via
    #   line == 32 ? StrategyServe.new : StrategyCall.new
    # so a Proc from a different line in mapper.rb would fall through to
    # StrategyCall — silently wrong. The identity-based fix only matches the
    # actual SERVE/CALL constants; anything else is NoOpProc.
    fake = ->(*_) { :not_a_strategy }
    fake_holder = StrategyHolder.new(fake)
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(fake_holder)
    replaced = fake_holder.instance_variable_get(:@strategy)
    refute_kind_of StrategyServe, replaced
    refute_kind_of StrategyCall, replaced
  end

  it "StrategyServe calls app.serve(req) and StrategyCall calls app.call(req.env)" do
    # Behavioural guard: a future regression that swaps the two strategies
    # is caught at the behaviour level, not just by class identity.
    serve_app = Object.new
    serve_app.define_singleton_method(:serve) { |req| "served:#{req}" }
    call_app = Object.new
    call_app.define_singleton_method(:call) { |env| "called:#{env}" }

    assert_equal "served:req1", StrategyServe.new.call(serve_app, "req1")
    env_obj = Object.new
    env_obj.define_singleton_method(:env) { "env1" }
    assert_equal "called:env1", StrategyCall.new.call(call_app, env_obj)
  end
end
end # AD_AVAILABLE
unless AD_AVAILABLE
  describe "StrategyProcSpec" do
    it "is skipped without actionpack in the bundle" do
      skip "action_dispatch not loadable — run under a Rails app bundle to exercise"
    end
  end
end