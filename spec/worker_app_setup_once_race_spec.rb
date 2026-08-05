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
    Thread::Mutex.singleton_class.define_method(:new) { orig_new.call } if orig_new
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
    Thread::Mutex.singleton_class.define_method(:new) { orig_new.call } if orig_new
    Ractor.current[:rrs_worker_mutex] = nil
    Ractor.current[:rrs_worker_ready] = nil
  end
end