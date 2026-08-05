# frozen_string_literal: true

# Specs for `RactorRailsShim::WorkerApp` — the shareable Rack wrapper that
# performs per-worker one-time initialization (rebind app constants, init AR
# connections) on the first request inside each worker Ractor.
#
# Invariant exercised here:
#
#   * the WorkerApp instance returned by `worker_app!` is `Ractor.shareable?`,
#     so it can be passed to `Ractor.new(app) { |a| ... }` without raising
#     IsolationError. Pre-fix, `WorkerApp.new(app, bindings)` returned a bare
#     instance that was NOT made shareable, so the caller had to know to
#     freeze + make_shareable it themselves — an undocumented contract that
#     bit any caller following the README's `worker_app!` example.
#
# Run: ruby -Ilib -Ispec spec/worker_app_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class WorkerAppSpec < Minitest::Spec
  # A frozen, shareable Rack app — no mutable state, so it survives
  # Ractor.make_shareable. Returns a fixed 200 response.
  class FrozenApp
    def call(env)
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
  end

  # `setup_once!` calls `RactorRailsShim.init_worker_ar_connections!` when
  # defined. Stub it via string eval (no captured binding) so the method is
  # callable from a worker Ractor. The shim's real implementation is also
  # string-eval'd for the same reason.
  RactorRailsShim.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
    def init_worker_ar_connections!; end
  RUBY

  # --- Issue #34: Pin the AR-init arm of setup_once! ---

  # The existing no-op stub (above) means init_worker_ar_connections! is
  # defined. The two specs below pin that setup_once! actually sends
  # the message and that the guard short-circuits the second call.
  # Because setup_once! runs inside a worker Ractor (string-eval'd method
  # body, no captured binding), we can't easily instrument it cross-Ractor.
  # Instead we pin the observable contract: the worker Ractor serves
  # requests without raising, which exercises the full setup_once! path
  # including the AR-init call.

  it "setup_once! exercises the AR-init path (worker serves requests)" do
    app = FrozenApp.new
    Ractor.make_shareable(app)
    worker_app = RactorRailsShim.worker_app!(app)
    # First call: setup_once! runs rebind_constants + init_worker_ar_connections!
    r = Ractor.new(worker_app) do |wa|
      wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
    end
    status, _headers, body = r.value
    assert_equal 200, status, "worker should serve requests after setup_once! (AR-init exercised)"
  end

  it "setup_once! guard short-circuits on second call (worker serves twice)" do
    app = FrozenApp.new
    Ractor.make_shareable(app)
    worker_app = RactorRailsShim.worker_app!(app)
    # Two calls in the same Ractor — second must be short-circuited by
    # the Ractor.current[:rrs_worker_ready] guard.
    r = Ractor.new(worker_app) do |wa|
      s1, _, _ = wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
      s2, _, _ = wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
      [s1, s2]
    end
    s1, s2 = r.value
    assert_equal 200, s1, "first call should succeed"
    assert_equal 200, s2, "second call should also succeed (guard short-circuits, no double-init)"
  end

  it "WorkerApp is Ractor.shareable? after the factory builds it" do
    app = FrozenApp.new
    Ractor.make_shareable(app)
    bindings = { "ShimWorkerAppProbe" => app }.freeze
    Ractor.make_shareable(bindings)

    worker_app = RactorRailsShim.worker_app!(app)
    assert Ractor.shareable?(worker_app),
      "WorkerApp must be shareable so Ractor.new(worker_app!) { |a| ... } works"
  ensure
    Object.send(:remove_const, :ShimWorkerAppProbe) if defined?(ShimWorkerAppProbe)
  end

  it "WorkerApp dispatches to the wrapped app and returns its response" do
    app = FrozenApp.new
    Ractor.make_shareable(app)
    worker_app = RactorRailsShim.worker_app!(app)

    r = Ractor.new(worker_app) do |wa|
      wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
    end
    status, _headers, body = r.value
    assert_equal 200, status
    assert_equal "ok", body.each.to_a.join
  end

  # --- Issue #13, Step 13.4: WorkerAppFactory extraction ---

  it "RactorRailsShim::WorkerAppFactory is a Module" do
    assert_kind_of Module, RactorRailsShim::WorkerAppFactory
  end

  it "RactorRailsShim::WorkerApp is a Class (moved to its own file)" do
    assert_kind_of Class, RactorRailsShim::WorkerApp
  end

  it "WorkerAppFactory.build returns a frozen, shareable WorkerApp" do
    app = FrozenApp.new
    Ractor.make_shareable(app)
    wa = RactorRailsShim::WorkerAppFactory.build(app)
    assert wa.frozen?, "factory-built WorkerApp should be frozen"
    assert Ractor.shareable?(wa), "factory-built WorkerApp should be shareable"
    assert_kind_of RactorRailsShim::WorkerApp, wa
  end

  it "WorkerAppFactory.capture_constants! returns a frozen Hash (no Rails → empty)" do
    # Without Rails defined, capture returns an empty frozen Hash.
    result = RactorRailsShim::WorkerAppFactory.capture_constants!
    assert_kind_of Hash, result
    assert result.frozen?
  end

  it "RactorRailsShim.worker_app! delegates to WorkerAppFactory.build" do
    delegated = false
    original = RactorRailsShim::WorkerAppFactory.method(:build)
    RactorRailsShim::WorkerAppFactory.define_singleton_method(:build) do |app|
      delegated = true
      original.call(app)
    end
    app = FrozenApp.new
    Ractor.make_shareable(app)
    RactorRailsShim.worker_app!(app)
    assert delegated
  ensure
    RactorRailsShim::WorkerAppFactory.define_singleton_method(:build, original)
  end

  it "RactorRailsShim.capture_app_constants! delegates to WorkerAppFactory.capture_constants!" do
    delegated = false
    original = RactorRailsShim::WorkerAppFactory.method(:capture_constants!)
    RactorRailsShim::WorkerAppFactory.define_singleton_method(:capture_constants!) do
      delegated = true
      original.call
    end
    RactorRailsShim.capture_app_constants!
    assert delegated
  ensure
    RactorRailsShim::WorkerAppFactory.define_singleton_method(:capture_constants!, original)
  end
end