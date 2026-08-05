# frozen_string_literal: true

# Specs for the naming convention (Step 10):
#   - Private methods carry a leading underscore.
#   - Public entry points (called from `install` / `prepare_for_ractors!`)
#     have no underscore and no bang, EXCEPT destructive lifecycle verbs
#     (prepare_for_ractors!, make_app_shareable!) and snapshot/build/freeze
#     methods that mutate global state, which take a bang.
#   - `do_install_*` is a leftover with no encoded meaning — it should be
#     renamed to a private bang method reflecting that it mutates the
#     @applied flag + reassigns constants.
#
# This spec asserts the *behavioural* contract of the renamed methods (they
# still do what they did before, under their new names), NOT the source text.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class NamingConventionSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # --- worker_app! (was worker_app) ---

  it "worker_app! is the public factory name (worker_app is gone)" do
    assert RactorRailsShim.respond_to?(:worker_app!),
           "worker_app! should be defined"
    refute RactorRailsShim.respond_to?(:worker_app),
           "worker_app (no bang) should be renamed to worker_app!"
  end

  it "worker_app! freezes + makes shareable + returns the WorkerApp" do
    app = Object.new
    def app.call(env); [200, {}, ["ok"]]; end
    app.freeze
    wa = RactorRailsShim.worker_app!(app)
    assert wa.frozen?
    assert Ractor.shareable?(wa)
  end

  # --- fix_url_helpers_singleton_routes! (was fix_url_helpers_singleton_routes) ---

  it "fix_url_helpers_singleton_routes! is the public name (no-bang gone)" do
    assert RactorRailsShim.respond_to?(:fix_url_helpers_singleton_routes!),
           "fix_url_helpers_singleton_routes! should be defined"
    refute RactorRailsShim.respond_to?(:fix_url_helpers_singleton_routes),
           "fix_url_helpers_singleton_routes (no bang) should be renamed"
  end

  # --- do_install_shareable_constants -> _apply_shareable_constants! ---

  it "_apply_shareable_constants! is the private worker name" do
    assert RactorRailsShim.respond_to?(:_apply_shareable_constants!, true),
           "_apply_shareable_constants! should be defined (private)"
    refute RactorRailsShim.method_defined?(:do_install_shareable_constants) &&
           RactorRailsShim.private_method_defined?(:do_install_shareable_constants),
           "do_install_shareable_constants should be renamed"
  end

  it "_apply_shareable_constants! is idempotent via @applied" do
    RactorRailsShim::ConstantShareabilizer.reset_applied!
    saved = RactorRailsShim::SHAREABLE_CONSTANTS.dup
    RactorRailsShim::SHAREABLE_CONSTANTS.replace([]) # vacuous: all resolve → flag sets
    RactorRailsShim.send(:_apply_shareable_constants!)
    assert RactorRailsShim::ConstantShareabilizer.applied?
  ensure
    RactorRailsShim::SHAREABLE_CONSTANTS.replace(saved) if saved
    RactorRailsShim::ConstantShareabilizer.reset_applied!
  end

  # --- Issue #20: mutating no-bang public methods renamed to bang versions ---

  it "make_constant_shareable! is the public name (no-bang gone) and delegates" do
    assert RactorRailsShim.respond_to?(:make_constant_shareable!),
           "make_constant_shareable! should be defined (mutating: calls const_set)"
    refute RactorRailsShim.respond_to?(:make_constant_shareable),
           "make_constant_shareable (no bang) should be renamed to make_constant_shareable!"
    # Delegates to the role object's bang method.
    assert RactorRailsShim::ConstantShareabilizer.respond_to?(:make_shareable!),
           "ConstantShareabilizer.make_shareable! should be defined"
    refute RactorRailsShim::ConstantShareabilizer.respond_to?(:make_shareable),
           "ConstantShareabilizer.make_shareable (no bang) should be renamed"
  end

  it "capture_app_constants! is the public name (no-bang gone) and delegates" do
    assert RactorRailsShim.respond_to?(:capture_app_constants!),
           "capture_app_constants! should be defined (mutating: calls Ractor.make_shareable)"
    refute RactorRailsShim.respond_to?(:capture_app_constants),
           "capture_app_constants (no bang) should be renamed to capture_app_constants!"
    # Delegates to the role object's bang method.
    assert RactorRailsShim::WorkerAppFactory.respond_to?(:capture_constants!),
           "WorkerAppFactory.capture_constants! should be defined"
    refute RactorRailsShim::WorkerAppFactory.respond_to?(:capture_constants),
           "WorkerAppFactory.capture_constants (no bang) should be renamed"
  end
end