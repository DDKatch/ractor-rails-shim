# frozen_string_literal: true

# Specs for Issue #13, Step 13.2: extract ShareabilityTraversal from the
# RactorRailsShim god module (POODR §1 SRP). The graph-traversal machinery —
# _collect_procs, _replace_unshareable_procs!, _replace_one_proc,
# _replace_locks_and_concurrent_maps!, _each_ivar_and_child,
# _enumerable_but_not_basic?, _introspectable?, _precompute_lazy_ivars,
# _generate_ar_attribute_methods!, _warm_attribute_method_patterns! — is one
# role collapsed onto the singleton. These specs pin the extracted object's
# contract directly (the container-coverage invariants currently tested only
# through make_shareable_spec) so the traversal is independently specable.
#
# The RactorRailsShim facade keeps delegating methods, so make_shareable_spec
# keeps passing unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/shareability_traversal_spec.rb

require "minitest/autorun"
require "set"
require "active_support/isolated_execution_state"
require "concurrent"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

SC = RactorRailsShim.singleton_class
NoOpLock = SC.const_get(:NoOpLock)
NoOpProc = SC.const_get(:NoOpProc)

class ShareabilityTraversalSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # --- namespace ---

  it "RactorRailsShim::ShareabilityTraversal is a Module" do
    assert_kind_of Module, RactorRailsShim::ShareabilityTraversal
  end

  # --- introspectable? ---

  it "introspectable? returns true for a normal Object" do
    assert RactorRailsShim::ShareabilityTraversal.introspectable?(Object.new)
  end

  it "introspectable? returns false for a BasicObject (no is_a?)" do
    basic = Class.new(BasicObject).new
    refute RactorRailsShim::ShareabilityTraversal.introspectable?(basic)
  end

  # --- enumerable_but_not_basic? ---

  it "enumerable_but_not_basic? returns false for Array/Hash/Set/Struct/String" do
    t = RactorRailsShim::ShareabilityTraversal
    refute t.enumerable_but_not_basic?([])
    refute t.enumerable_but_not_basic?({})
    refute t.enumerable_but_not_basic?(Set.new)
    refute t.enumerable_but_not_basic?(Struct.new(:x).new)
    refute t.enumerable_but_not_basic?("str")
  end

  it "enumerable_but_not_basic? returns true for a generic Enumerable (Range)" do
    assert RactorRailsShim::ShareabilityTraversal.enumerable_but_not_basic?(1..3)
  end

  it "enumerable_but_not_basic? returns false for a non-Enumerable Object" do
    refute RactorRailsShim::ShareabilityTraversal.enumerable_but_not_basic?(Object.new)
  end

  # --- replace_locks_and_concurrent_maps! ---

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
    def initialize; @inner_lock = Mutex.new; end
    attr_reader :inner_lock
  end

  it "replace_locks_and_concurrent_maps! rewrites Mutex/Monitor → NoOpLock and Concurrent::Map → Hash" do
    app = FakeApp.new
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(app)

    assert_kind_of NoOpLock, app.lock
    assert_kind_of NoOpLock, app.monitor
    assert_kind_of Hash, app.cache
    assert_equal "bar", app.cache[:foo]
    assert_kind_of NoOpLock, app.children.first.inner_lock
    assert_kind_of NoOpLock, app.children.last.inner_lock
    assert_kind_of NoOpLock, app.lookup[:nested].inner_lock
  end

  it "after replace_locks_and_concurrent_maps! + make_shareable the graph is shareable" do
    app = FakeApp.new
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(app)
    Ractor.make_shareable(app)
    assert Ractor.shareable?(app)
  end

  # --- container coverage (Set / Struct) ---

  class SetAndStructHolder
    attr_reader :set_with_lock, :struct_with_lock
    def initialize
      @set_with_lock = Set.new([ChildWithLock.new])
      @struct_with_lock = Struct.new(:member).new(ChildWithLock.new)
    end
  end

  it "replace_locks_and_concurrent_maps! walks Set members and replaces nested Mutexes" do
    holder = SetAndStructHolder.new
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(holder)
    assert_kind_of NoOpLock, holder.set_with_lock.first.inner_lock
  end

  it "replace_locks_and_concurrent_maps! walks Struct members and replaces nested Mutexes" do
    holder = SetAndStructHolder.new
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(holder)
    assert_kind_of NoOpLock, holder.struct_with_lock.member.inner_lock
  end

  # --- replace_unshareable_procs! ---

  it "replace_unshareable_procs! walks Set members and replaces nested Procs" do
    proc_holder = Class.new do
      def initialize; @p = ->(*) { :set_proc }; end
      attr_reader :p
    end.new
    set_holder = Set.new([proc_holder])
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(set_holder)
    refute_kind_of Proc, proc_holder.p
    assert_kind_of NoOpProc, proc_holder.p
  end

  class SharedProcHolder
    attr_reader :a, :b, :c
    def initialize
      shared = ->(*) { :shared }
      @a = shared
      @b = [@a, @a]
      @c = { nested: @a, other: @a }
    end
  end

  it "replace_unshareable_procs! replaces every occurrence of a shared Proc (multi-pass to fixed point)" do
    holder = SharedProcHolder.new
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)
    refute_kind_of Proc, holder.a
    assert_kind_of NoOpProc, holder.a
    assert_kind_of NoOpProc, holder.b[0]
    assert_kind_of NoOpProc, holder.b[1]
    assert_kind_of NoOpProc, holder.c[:nested]
    assert_kind_of NoOpProc, holder.c[:other]
  end

  it "replace_unshareable_procs! converges and leaves a shareable graph" do
    holder = SharedProcHolder.new
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)
    Ractor.make_shareable(holder)
    assert Ractor.shareable?(holder)
  end

  # --- precompute_lazy_ivars / generate_ar_attribute_methods! / warm_attribute_method_patterns! ---

  it "precompute_lazy_ivars is a no-op for a stubbed app that rescues all calls" do
    # The method calls app.env_config (un-rescued) then app.app_env_config,
    # app.routes.* (each rescued nil). A stub object responding to env_config
    # and routes should not raise.
    obj = Object.new
    def obj.env_config; nil; end
    def obj.app_env_config; nil; end
    def obj.routes; o = Object.new; def o.url_helpers; nil; end; def o.named_routes; nil; end; def o.helpers; nil; end; o; end
    assert_nil RactorRailsShim::ShareabilityTraversal.precompute_lazy_ivars(obj)
  end

  it "generate_ar_attribute_methods! is a no-op when ActiveRecord::Base is not defined" do
    # Must not raise; returns nil.
    assert_nil RactorRailsShim::ShareabilityTraversal.generate_ar_attribute_methods!
  end

  it "warm_attribute_method_patterns! is a no-op when ActiveRecord::Base is not defined" do
    assert_nil RactorRailsShim::ShareabilityTraversal.warm_attribute_method_patterns!
  end

  # --- Facade delegation ---

  it "RactorRailsShim._introspectable? delegates to ShareabilityTraversal.introspectable?" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:introspectable?)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:introspectable?) do |o|
      delegated = true
      original.call(o)
    end
    RactorRailsShim._introspectable?(Object.new)
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:introspectable?, original)
  end

  it "RactorRailsShim._replace_unshareable_procs! delegates to ShareabilityTraversal.replace_unshareable_procs!" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:replace_unshareable_procs!)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:replace_unshareable_procs!) do |app|
      delegated = true
      original.call(app)
    end
    RactorRailsShim._replace_unshareable_procs!(SharedProcHolder.new)
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:replace_unshareable_procs!, original)
  end

  it "RactorRailsShim._replace_locks_and_concurrent_maps! delegates to ShareabilityTraversal.replace_locks_and_concurrent_maps!" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:replace_locks_and_concurrent_maps!)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:replace_locks_and_concurrent_maps!) do |app|
      delegated = true
      original.call(app)
    end
    RactorRailsShim._replace_locks_and_concurrent_maps!(FakeApp.new)
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:replace_locks_and_concurrent_maps!, original)
  end

  it "RactorRailsShim._precompute_lazy_ivars delegates to ShareabilityTraversal.precompute_lazy_ivars" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:precompute_lazy_ivars)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:precompute_lazy_ivars) do |app|
      delegated = true
    end
    RactorRailsShim._precompute_lazy_ivars(Object.new)
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:precompute_lazy_ivars, original)
  end

  it "RactorRailsShim._generate_ar_attribute_methods! delegates to ShareabilityTraversal.generate_ar_attribute_methods!" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:generate_ar_attribute_methods!)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:generate_ar_attribute_methods!) do
      delegated = true
      original.call
    end
    RactorRailsShim._generate_ar_attribute_methods!
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:generate_ar_attribute_methods!, original)
  end

  it "RactorRailsShim._warm_attribute_method_patterns! delegates to ShareabilityTraversal.warm_attribute_method_patterns!" do
    delegated = false
    original = RactorRailsShim::ShareabilityTraversal.method(:warm_attribute_method_patterns!)
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:warm_attribute_method_patterns!) do
      delegated = true
      original.call
    end
    RactorRailsShim._warm_attribute_method_patterns!
    assert delegated
  ensure
    RactorRailsShim::ShareabilityTraversal.define_singleton_method(:warm_attribute_method_patterns!, original)
  end
end