# frozen_string_literal: true

# Specs for the `RactorRailsShim::ControllerCollector` role object
# (extracted from the facade god module in Step 22.4, Issue #22).
#
# These specs target the role object directly — calling
# `ControllerCollector.call(app)` — pinning both branches (routes walk +
# descendants) and the `compact.uniq` dedup without routing through the
# facade.
#
# Run: ruby -Ilib -Ispec spec/controller_collector_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require "active_support/core_ext/string/inflections"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ControllerCollectorSpec < Minitest::Spec
  # The role object exists and exposes the call entry point.
  it "is a module under RactorRailsShim with a .call method" do
    assert RactorRailsShim.const_defined?(:ControllerCollector, false),
           "RactorRailsShim::ControllerCollector should be defined"
    assert RactorRailsShim::ControllerCollector.respond_to?(:call),
           "ControllerCollector.call should be defined"
  end

  # Routes walk branch: walks app.routes, camelizes the controller default,
  # safe_constantizes the class name, and collects the class.
  it "walks app.routes and collects controller classes from defaults" do
    fake_controller = Class.new
    Object.const_set(:FakeRoutesController, fake_controller) unless defined?(FakeRoutesController)

    route1 = Object.new
    def route1.defaults; { controller: "fake_routes" }; end
    route2 = Object.new
    def route2.defaults; { controller: "fake_routes" }; end
    route3 = Object.new
    def route3.defaults; { controller: "nonexistent_xyz" }; end

    # app.routes returns a router object with a .routes method (matching
    # the real Rails::Engine::LazyRouteSet / ActionDispatch::Routing::RouteSet
    # shape — app.routes is the route set, .routes is the array of routes).
    routes_set = Object.new
    routes_set.define_singleton_method(:routes) { [route1, route2, route3] }
    app = Object.new
    app.define_singleton_method(:routes) { routes_set }

    result = RactorRailsShim::ControllerCollector.call(app)
    assert_includes result, fake_controller,
                    "should collect FakeRoutesController from the routes walk"
    # route1 and route2 both resolve to the same controller; uniq dedups.
    assert_equal 1, result.count(fake_controller),
                 "duplicate controller references should be deduped"
  ensure
    Object.send(:remove_const, :FakeRoutesController) if defined?(FakeRoutesController)
  end

  # Descendants branch: concats ApplicationController.descendants.
  it "concats ApplicationController.descendants when defined" do
    fake_base = Class.new
    fake_descendant = Class.new(fake_base)
    fake_base.define_singleton_method(:descendants) { [fake_descendant] }
    Object.send(:remove_const, :ApplicationController) if defined?(::ApplicationController)
    Object.const_set(:ApplicationController, fake_base)

    app = empty_routes_app
    result = RactorRailsShim::ControllerCollector.call(app)
    assert_includes result, fake_descendant,
                    "should include ApplicationController.descendants"
  ensure
    Object.send(:remove_const, :ApplicationController) if defined?(::ApplicationController) &&
      defined?(fake_base) && ::ApplicationController.equal?(fake_base)
  end

  # Both branches are funneled through _swallow; a routes failure does not
  # prevent the descendants branch from running.
  it "funnels routes failure through _swallow and still runs descendants" do
    fake_base = Class.new
    fake_descendant = Class.new(fake_base)
    fake_base.define_singleton_method(:descendants) { [fake_descendant] }
    Object.send(:remove_const, :ApplicationController) if defined?(::ApplicationController)
    Object.const_set(:ApplicationController, fake_base)

    app = Object.new
    def app.routes; raise RuntimeError, "forced-routes-failure"; end
    result = RactorRailsShim::ControllerCollector.call(app)
    # The routes branch is funneled through _swallow (no raise); the
    # descendants branch still runs.
    assert_includes result, fake_descendant,
                    "descendants branch should run even if routes fail"
  ensure
    Object.send(:remove_const, :ApplicationController) if defined?(::ApplicationController) &&
      defined?(fake_base) && ::ApplicationController.equal?(fake_base)
  end

  # Returns a compacted, uniq array.
  it "returns a compacted, uniq array" do
    app = empty_routes_app
    result = RactorRailsShim::ControllerCollector.call(app)
    assert_kind_of Array, result
    # No nil entries (compact), no duplicates (uniq).
    assert result.none?(nil), "result should have no nil entries"
    assert result.uniq == result, "result should have no duplicates"
  end

  # The facade delegates to the role object.
  it "facade _collect_controller_classes delegates to the role object" do
    app = empty_routes_app
    result = RactorRailsShim.send(:_collect_controller_classes, app)
    assert_kind_of Array, result
  end

  private

  # Build an app whose .routes returns an empty routes set (matching the
  # real Rails shape: app.routes is a route set with a .routes method).
  def empty_routes_app
    routes_set = Object.new
    routes_set.define_singleton_method(:routes) { [] }
    app = Object.new
    app.define_singleton_method(:routes) { routes_set }
    app
  end
end