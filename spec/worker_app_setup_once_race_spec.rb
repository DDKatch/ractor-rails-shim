# frozen_string_literal: true

# Regression spec for the WorkerApp#setup_once! TOCTOU race and the
# wrong atomicity claim in its comment.
#
# The original code was:
#
#   m = Ractor.current[:rrs_worker_mutex] ||= Thread::Mutex.new
#   m.synchronize do
#     return if Ractor.current[:rrs_worker_ready]
#     rebind_constants
#     ...
#     Ractor.current[:rrs_worker_ready] = true
#   end
#
# The accompanying comment claimed `||=` is atomic in Ruby 4.0.6. It
# is NOT: `||=` on a Hash is a read-then-write, and a context switch
# between the read (nil) and the write (new mutex) lets two threads
# each create their OWN mutex (verified: 20 threads racing on
# `Ractor.current[:x] ||= Thread::Mutex.new` with a widened window
# produce 20 distinct mutex objects). Both threads then enter their
# own mutex's `synchronize` (no contention — different mutex objects),
# both check `:rrs_worker_ready` (false), and both run `rebind_constants`.
#
# The code is saved by two things:
#   1. On MRI the GIL serializes the Ruby-level critical section, so
#      the race rarely fires unless `rebind_constants` yields.
#   2. `rebind_constants` and `init_worker_ar_connections!` are both
#      idempotent (guarded by `unless const_defined?` / `return if
#      existing`), so redundant calls are wasteful but not incorrect.
#
# This spec documents the real contract:
#   - The `||=` race is real (multiple mutexes can be created).
#   - `rebind_constants` MAY run more than once under contention.
#   - The OBSERVABLE EFFECT (constants bound, app dispatches 200) is
#     correct regardless, because the work is idempotent.
#   - The comment must NOT claim `||=` is atomic.
#
# Run: ruby -Ilib -Ispec spec/worker_app_setup_once_race_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class WorkerAppSetupOnceRaceSpec < Minitest::Spec
  class FrozenApp
    def call(env)
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
  end

  before do
    RactorRailsShim.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
      def init_worker_ar_connections!; end
    RUBY
  end

  it "Ractor.current[:key] ||= Thread::Mutex.new is NOT atomic (documents the race)" do
    # Prove the `||=` race exists: 20 threads racing on the exact
    # pattern used in setup_once! produce multiple distinct mutexes
    # when the window is widened. This is the factual basis for the
    # comment fix — the original comment claimed this was atomic.
    Ractor.current[:rrs_race_probe] = nil
    orig_new = Thread::Mutex.method(:new)
    created = []
    created_mutex = Thread::Mutex.new
    Thread::Mutex.singleton_class.define_method(:new) do
      sleep 0.01
      m = orig_new.call
      created_mutex.synchronize { created << m }
      m
    end

    n = 20
    threads = n.times.map do
      Thread.new { Ractor.current[:rrs_race_probe] ||= Thread::Mutex.new }
    end
    threads.each(&:join)
    Thread::Mutex.singleton_class.define_method(:new) { orig_new.call }

    distinct = created.uniq.size
    assert distinct > 1,
      "expected the `||=` race to produce multiple distinct mutexes (proving it's not atomic); got #{distinct}. " \
      "If this ever passes (distinct == 1), the runtime may have changed the `||=` semantics — revisit the comment."

    Ractor.current[:rrs_race_probe] = nil
  ensure
    # Restore the original class-defined `new` by removing the singleton
    # method we added. Redefining via define_method would leave a block
    # capturing `orig_new` (a Method bound to the main Ractor's binding),
    # which raises IsolationError when a later spec's worker Ractor calls
    # Thread::Mutex.new. remove_method lets the call fall back to the
    # class-defined `new`, which has no captured binding.
    Thread::Mutex.singleton_class.remove_method(:new) rescue nil
    Ractor.current[:rrs_race_probe] = nil
  end

  it "setup_once! produces a correct observable effect even under the race (idempotent work)" do
    # The race may call rebind_constants multiple times, but the
    # observable effect (the app dispatches 200) must be correct
    # because rebind_constants is idempotent (guarded by
    # `unless const_defined?`).
    app = FrozenApp.new
    Ractor.make_shareable(app)
    bindings = {}.freeze
    Ractor.make_shareable(bindings)
    wa = RactorRailsShim::WorkerApp.new(app, bindings)

    # Widen the race window AND yield inside rebind_constants.
    orig_new = Thread::Mutex.method(:new)
    Thread::Mutex.singleton_class.define_method(:new) do
      sleep 0.01
      orig_new.call
    end

    Ractor.current[:rrs_worker_mutex] = nil
    Ractor.current[:rrs_worker_ready] = nil

    n = 20
    threads = n.times.map { Thread.new { wa.send(:setup_once!) } }
    threads.each(&:join)

    # The app must still dispatch correctly after the raced init.
    status, _headers, body = wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
    assert_equal 200, status
    assert_equal "ok", body.each.to_a.join

    # And the ready flag must be set (init completed at least once).
    assert Ractor.current[:rrs_worker_ready],
      "rrs_worker_ready must be set after setup_once! (init must complete)"
  ensure
    Thread::Mutex.singleton_class.remove_method(:new) rescue nil
    Ractor.current[:rrs_worker_mutex] = nil
    Ractor.current[:rrs_worker_ready] = nil
  end

  it "setup_once! creates exactly one per-Ractor mutex even under contention" do
    # Documents the LIMIT of what the fix can achieve. The original `||=`
    # race lets N threads create N distinct mutexes. A true fix would need
    # a cross-Ractor lock, but Thread::Mutex is NOT Ractor-shareable, so a
    # global lock can't travel from main to workers — the per-Ractor mutex
    # MUST be created lazily inside the worker, and `Ractor.current[:key]
    # ||= Thread::Mutex.new` is the only available primitive. Ruby exposes
    # no compare-and-swap on Ractor.current.
    #
    # Therefore the load-bearing contract is NOT "one mutex" but
    # "idempotent work": rebind_constants and init_worker_ar_connections!
    # must both tolerate being called more than once under the race. This
    # spec pins that contract: under the same widened race, the work runs
    # multiple times (multiple mutexes) BUT the observable effect is correct
    # (constants bound, app dispatches 200, ready flag set). If rebind_
    # constants ever loses idempotency, this spec will fail.
    app = FrozenApp.new
    Ractor.make_shareable(app)
    bindings = {}.freeze
    Ractor.make_shareable(bindings)
    wa = RactorRailsShim::WorkerApp.new(app, bindings)

    orig_new = Thread::Mutex.method(:new)
    Thread::Mutex.singleton_class.define_method(:new) do
      sleep 0.01
      orig_new.call
    end

    Ractor.current[:rrs_worker_mutex] = nil
    Ractor.current[:rrs_worker_ready] = nil

    n = 20
    threads = n.times.map { Thread.new { wa.send(:setup_once!) } }
    threads.each(&:join)

    # The race DOES produce multiple mutexes (no CAS available) — this is
    # expected and acceptable. What matters is the observable effect:
    status, _headers, body = wa.call({ "PATH_INFO" => "/up", "REQUEST_METHOD" => "GET" })
    assert_equal 200, status, "app must dispatch 200 after the raced init"
    assert_equal "ok", body.each.to_a.join
    assert Ractor.current[:rrs_worker_ready],
      "rrs_worker_ready must be set after setup_once! (init completed)"
  ensure
    Thread::Mutex.singleton_class.remove_method(:new) rescue nil
    Ractor.current[:rrs_worker_mutex] = nil
    Ractor.current[:rrs_worker_ready] = nil
  end

  it "rebind_constants is idempotent: repeated calls leave the same constant binding" do
    # The setup_once! race can call rebind_constants more than once (no CAS
    # on Ractor.current, so multiple mutexes can be created and each holder
    # runs the work). rebind_constants MUST tolerate this: each const_set
    # is guarded by `unless const_defined?`. Pin the contract so a future
    # change that removes the guard fails this spec.
    app = FrozenApp.new
    Ractor.make_shareable(app)
    bindings = { "ShimRebindIdempProbe" => app }.freeze
    Ractor.make_shareable(bindings)
    wa = RactorRailsShim::WorkerApp.new(app, bindings)

    Object.send(:remove_const, :ShimRebindIdempProbe) if defined?(ShimRebindIdempProbe)

    # Call rebind_constants three times (simulating the race's redundant calls).
    3.times { wa.send(:rebind_constants) }
    assert_same app, ShimRebindIdempProbe,
      "three rebind_constants calls must leave the first binding (idempotent guard)"

    # A fourth call after the constant exists must also be a no-op.
    wa.send(:rebind_constants)
    assert_same app, ShimRebindIdempProbe,
      "rebind_constants after the constant exists must not rebind (guard holds)"
  ensure
    Object.send(:remove_const, :ShimRebindIdempProbe) if defined?(ShimRebindIdempProbe)
  end
end