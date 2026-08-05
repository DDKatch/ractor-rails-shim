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
end