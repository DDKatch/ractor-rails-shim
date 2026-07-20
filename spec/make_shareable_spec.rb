# frozen_string_literal: true

# Specs for `RactorRailsShim.make_app_shareable!` and the replacement
# primitives it uses (NoOpLock, NoOpProc, Callable, CallableConst). The full
# `make_app_shareable!` pipeline requires a booted Rails app (exercised by
# `spec/integration_spec.rb`); these specs verify the primitive-level
# invariants that make the pipeline work:
#
#   * the replacement classes are Ractor-shareable after construction
#   * they're callable from a worker Ractor (no captured binding)
#   * `_replace_locks_and_concurrent_maps!` swaps Mutex/Monitor → NoOpLock and
#     Concurrent::Map → frozen Hash in an arbitrary object graph
#   * the resulting graph is `Ractor.shareable?`
#   * a worker Ractor can call into the shareable graph
#
# Run: ruby -Ilib -Ispec spec/make_shareable_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require "concurrent" # for Concurrent::Map, used by Rails caches the rewriter targets
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class MakeShareableSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # The replacement classes are defined via `module_eval` on the shim's
  # singleton class (so specs access them via RactorRailsShim.singleton_class),
  # per the comment at make_shareable.rb:340-343.
  NoOpLock    = RactorRailsShim.singleton_class.const_get(:NoOpLock)
  NoOpProc    = RactorRailsShim.singleton_class.const_get(:NoOpProc)
  Callable    = RactorRailsShim.singleton_class.const_get(:Callable)
  CallableConst = RactorRailsShim.singleton_class.const_get(:CallableConst)

  # --- primitive shareability ---
  #
  # The replacement classes are constructed in main and then made shareable
  # by `Ractor.make_shareable` during the real `make_app_shareable!` pipeline.
  # Bare instances are NOT necessarily `Ractor.shareable?` until
  # `make_shareable` runs (the class itself may not be shareable until the
  # class graph is frozen). We assert the post-`make_shareable` invariant,
  # which is the one that matters for cross-Ractor use.

  it "NoOpLock is Ractor-shareable after make_shareable and behaves as a no-op lock" do
    lock = NoOpLock.new
    Ractor.make_shareable(lock)
    assert Ractor.shareable?(lock), "NoOpLock should be shareable after make_shareable"
    result = lock.synchronize { :worked }
    assert_equal :worked, result
    assert lock.try_lock, "try_lock always returns true"
    refute lock.locked?
    refute lock.mon_locked?
  end

  it "NoOpProc is Ractor-shareable after make_shareable and calls return nil" do
    p = NoOpProc.new
    Ractor.make_shareable(p)
    assert Ractor.shareable?(p), "NoOpProc should be shareable after make_shareable"
    assert_nil p.call(:anything, 42)
    # to_proc must return a callable (used by `&block` implicit conversion).
    assert_kind_of Proc, p.to_proc
    assert_nil p.to_proc.call(:x)
  end

  it "Callable routes .call to target.__send__(method_name, *args)" do
    target = Object.new
    def target.greet(name); "hi #{name}"; end
    c = Callable.new(target, :greet)
    assert_equal "hi world", c.call("world")
  end

  it "CallableConst returns a constant value and is shareable when the value is" do
    val = [1, 2, 3].freeze
    Ractor.make_shareable(val)
    cc = CallableConst.new(val)
    Ractor.make_shareable(cc)
    assert Ractor.shareable?(cc), "CallableConst around a shareable value should be shareable"
    assert_equal val, cc.call(:ignored)
    assert_equal val, cc.call
  end

  # --- cross-Ractor callability (the whole point of the shim) ---

  it "a NoOpLock and NoOpProc are usable from a worker Ractor" do
    lock = NoOpLock.new
    np = NoOpProc.new
    Ractor.make_shareable(lock)
    Ractor.make_shareable(np)
    r = Ractor.new(lock, np) do |l, p|
      [l.synchronize { :ok }, p.call(:x)]
    end
    assert_equal [:ok, nil], r.value
  end

  # --- _replace_locks_and_concurrent_maps! graph rewrite ---

  # A fake app graph with a Mutex, a Monitor, and a Concurrent::Map, nested
  # inside instance variables, Arrays, and Hashes — the shapes the real
  # replacement pass walks.
  class FakeApp
    def initialize
      @lock = Mutex.new
      @monitor = Monitor.new
      @cache = Concurrent::Map.new
      @cache[:foo] = "bar"
      @children = [ChildWithLock.new, ChildWithLock.new]
      @lookup = { nested: ChildWithLock.new }
    end
    attr_reader :lock, :monitor, :cache, :children, :lookup
  end

  class ChildWithLock
    def initialize
      @inner_lock = Mutex.new
    end
    attr_reader :inner_lock
  end

  it "_replace_locks_and_concurrent_maps! rewrites Mutex/Monitor → NoOpLock and Concurrent::Map → Hash" do
    app = FakeApp.new
    RactorRailsShim.send(:_replace_locks_and_concurrent_maps!, app)

    assert_kind_of NoOpLock, app.lock,
      "top-level Mutex should be replaced with NoOpLock"
    assert_kind_of NoOpLock, app.monitor,
      "top-level Monitor should be replaced with NoOpLock"

    # Concurrent::Map → plain Hash (entries preserved)
    assert_kind_of Hash, app.cache
    assert_equal "bar", app.cache[:foo]

    # Nested children in Arrays
    assert_kind_of NoOpLock, app.children.first.inner_lock
    assert_kind_of NoOpLock, app.children.last.inner_lock

    # Nested children in Hashes
    assert_kind_of NoOpLock, app.lookup[:nested].inner_lock
  end

  it "the rewritten graph is Ractor.shareable? after make_shareable" do
    # `_replace_locks_and_concurrent_maps!` swaps unshareable Mutex/Monitor/
    # Concurrent::Map instances for shareable stand-ins, but does NOT freeze
    # the surrounding graph — that's `Ractor.make_shareable`'s job (called
    # at the end of the real `make_app_shareable!` pipeline). Verify the
    # combined invariant: after rewrite + make_shareable, the graph is
    # shareable.
    app = FakeApp.new
    RactorRailsShim.send(:_replace_locks_and_concurrent_maps!, app)
    Ractor.make_shareable(app)
    assert Ractor.shareable?(app),
      "rewritten + make_shareable graph should be Ractor.shareable?"
  end

  it "a worker Ractor can read the rewritten + shared graph" do
    app = FakeApp.new
    RactorRailsShim.send(:_replace_locks_and_concurrent_maps!, app)
    Ractor.make_shareable(app)
    r = Ractor.new(app) do |a|
      [
        a.lock.synchronize { :from_worker },
        a.cache[:foo],
        a.children.first.inner_lock.locked?,
      ]
    end
    assert_equal [:from_worker, "bar", false], r.value
  end

  # --- make_app_shareable! end-to-end ---
  #
  # The full `make_app_shareable!` pipeline requires a booted Rails
  # application (it calls `Rails.application.env_config`, warms Journey
  # routes, etc.). That end-to-end path is exercised by
  # `spec/integration_spec.rb`. We do NOT replicate it here with a fake app
  # because the Rails-dependent sub-steps would needlessly stub half of
  # Rails. The primitive-level invariants above are what make the pipeline
  # correct; the integration spec proves the pipeline as a whole.
end