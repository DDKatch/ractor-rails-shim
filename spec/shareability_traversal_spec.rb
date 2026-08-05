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
  # The facade delegations (_introspectable?, _replace_unshareable_procs!,
  # _replace_locks_and_concurrent_maps!, _precompute_lazy_ivars,
  # _generate_ar_attribute_methods!, _warm_attribute_method_patterns!)
  # were deleted in Issue #31. The role-object methods are tested directly
  # above. The facade no longer forwards to them.

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # ShareabilityTraversal reaches many collaborators through the
  # RactorRailsShim facade by global name:
  #   - callables: _swallow (funnel), _find_files_server,
  #     _devise_mapping_replacement, _strategy_replacement_for
  #   - callable classes: NoOpLock, NoOpProc, Callable, CallableConst,
  #     RequestCallable (via singleton_class.const_get)
  #   - LOC strings: SSL_LOC, FILES_LOC, COOKIE_LOC, DEVISE_SCOPE_LOC,
  #     MAPPER_LOC (via RactorRailsShim::CONST)
  # The seam is `configure(...)`; the defaults are the facade lookups so
  # existing call sites keep working. Issue #25 will group the constants
  # into a Registry; until then they're flat kwargs on the seam.

  it "responds to configure and reset_configuration" do
    assert_respond_to RactorRailsShim::ShareabilityTraversal, :configure
    assert_respond_to RactorRailsShim::ShareabilityTraversal, :reset_configuration
  end

  it "responds to the four callable-collaborator readers" do
    %i[funnel find_files_server devise_mapping_replacement strategy_replacement_for].each do |m|
      assert_respond_to RactorRailsShim::ShareabilityTraversal, m
    end
  end

  it "responds to the five callable-class readers" do
    %i[noop_lock_class noop_proc_class callable_class callable_const_class request_callable_class].each do |m|
      assert_respond_to RactorRailsShim::ShareabilityTraversal, m
    end
  end

  it "responds to the five LOC-string readers" do
    %i[ssl_loc files_loc cookie_loc devise_scope_loc mapper_loc].each do |m|
      assert_respond_to RactorRailsShim::ShareabilityTraversal, m
    end
  end

  it "configure injects the callable collaborators" do
    ffs = ->(mw) { :ffs }
    dmr = ->(p, pr) { :dmr }
    srf = ->(p) { :srf }
    funnel = ->(label, &blk) { blk&.call rescue StandardError; }
    RactorRailsShim::ShareabilityTraversal.configure(
      funnel: funnel, find_files_server: ffs,
      devise_mapping_replacement: dmr, strategy_replacement_for: srf
    )
    assert_equal ffs, RactorRailsShim::ShareabilityTraversal.find_files_server
    assert_equal dmr, RactorRailsShim::ShareabilityTraversal.devise_mapping_replacement
    assert_equal srf, RactorRailsShim::ShareabilityTraversal.strategy_replacement_for
    assert_equal funnel, RactorRailsShim::ShareabilityTraversal.funnel
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "configure injects the callable-class collaborators" do
    nl = Class.new
    np = Class.new
    cb = Class.new
    cc = Class.new
    rc = Class.new
    RactorRailsShim::ShareabilityTraversal.configure(
      noop_lock_class: nl, noop_proc_class: np, callable_class: cb,
      callable_const_class: cc, request_callable_class: rc
    )
    assert_equal nl, RactorRailsShim::ShareabilityTraversal.noop_lock_class
    assert_equal np, RactorRailsShim::ShareabilityTraversal.noop_proc_class
    assert_equal cb, RactorRailsShim::ShareabilityTraversal.callable_class
    assert_equal cc, RactorRailsShim::ShareabilityTraversal.callable_const_class
    assert_equal rc, RactorRailsShim::ShareabilityTraversal.request_callable_class
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "configure injects the LOC-string collaborators" do
    RactorRailsShim::ShareabilityTraversal.configure(
      ssl_loc: "/x/ssl.rb", files_loc: "/x/files.rb", cookie_loc: "/x/cookie.rb",
      devise_scope_loc: "/x/devise.rb", mapper_loc: "/x/mapper.rb"
    )
    assert_equal "/x/ssl.rb", RactorRailsShim::ShareabilityTraversal.ssl_loc
    assert_equal "/x/files.rb", RactorRailsShim::ShareabilityTraversal.files_loc
    assert_equal "/x/cookie.rb", RactorRailsShim::ShareabilityTraversal.cookie_loc
    assert_equal "/x/devise.rb", RactorRailsShim::ShareabilityTraversal.devise_scope_loc
    assert_equal "/x/mapper.rb", RactorRailsShim::ShareabilityTraversal.mapper_loc
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "replace_locks_and_concurrent_maps! funnels through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    RactorRailsShim::ShareabilityTraversal.configure(funnel: funnel)
    holder = Object.new
    holder.instance_variable_set(:@lock, Mutex.new)
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(holder)
    assert_includes funneled, "replace lock ivar"
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "replace_locks_and_concurrent_maps! uses an injected noop_lock_class" do
    fake_lock_class = Class.new
    RactorRailsShim::ShareabilityTraversal.configure(
      noop_lock_class: fake_lock_class,
      funnel: ->(label, &blk) { blk&.call rescue StandardError; }
    )
    holder = Object.new
    holder.instance_variable_set(:@lock, Mutex.new)
    RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(holder)
    assert_kind_of fake_lock_class, holder.instance_variable_get(:@lock),
                   "Mutex should be replaced with an instance of the injected lock class"
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "replace_unshareable_procs! routes proc-ivar swaps through an injected funnel" do
    funneled = []
    funnel = ->(label, &blk) { funneled << label; blk&.call rescue StandardError; }
    noop_proc_class = Class.new
    RactorRailsShim::ShareabilityTraversal.configure(
      funnel: funnel, noop_proc_class: noop_proc_class
    )
    holder = Object.new
    holder.instance_variable_set(:@proc, Proc.new { })
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)
    assert_includes funneled, "replace proc ivar"
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "replace_unshareable_procs! uses an injected noop_proc_class for unknown Procs" do
    noop_proc_class = Class.new
    RactorRailsShim::ShareabilityTraversal.configure(
      noop_proc_class: noop_proc_class,
      funnel: ->(label, &blk) { blk&.call rescue StandardError; }
    )
    holder = Object.new
    p = Proc.new { }
    holder.instance_variable_set(:@proc, p)
    RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(holder)
    assert_kind_of noop_proc_class, holder.instance_variable_get(:@proc),
                   "unknown Proc should be replaced with an instance of the injected noop_proc_class"
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults" do
    sc = RactorRailsShim.singleton_class
    RactorRailsShim::ShareabilityTraversal.configure(
      funnel: ->(label, &blk) { blk&.call },
      find_files_server: ->(mw) { },
      devise_mapping_replacement: ->(p, pr) { },
      strategy_replacement_for: ->(p) { },
      noop_lock_class: Class.new, noop_proc_class: Class.new,
      callable_class: Class.new, callable_const_class: Class.new,
      request_callable_class: Class.new,
      ssl_loc: "a", files_loc: "b", cookie_loc: "c",
      devise_scope_loc: "d", mapper_loc: "e"
    )
    refute_equal RactorRailsShim::Funnel.method(:swallow), RactorRailsShim::ShareabilityTraversal.funnel
    refute_equal RactorRailsShim.method(:_find_files_server), RactorRailsShim::ShareabilityTraversal.find_files_server

    RactorRailsShim::ShareabilityTraversal.reset_configuration
    assert_equal RactorRailsShim::Funnel.method(:swallow), RactorRailsShim::ShareabilityTraversal.funnel
    assert_equal RactorRailsShim.method(:_find_files_server), RactorRailsShim::ShareabilityTraversal.find_files_server
    assert_equal RactorRailsShim.method(:_devise_mapping_replacement), RactorRailsShim::ShareabilityTraversal.devise_mapping_replacement
    assert_equal RactorRailsShim::ActionDispatchStrategy.method(:replacement_for), RactorRailsShim::ShareabilityTraversal.strategy_replacement_for
    assert_equal sc.const_get(:NoOpLock), RactorRailsShim::ShareabilityTraversal.noop_lock_class
    assert_equal sc.const_get(:NoOpProc), RactorRailsShim::ShareabilityTraversal.noop_proc_class
    assert_equal sc.const_get(:Callable), RactorRailsShim::ShareabilityTraversal.callable_class
    assert_equal sc.const_get(:CallableConst), RactorRailsShim::ShareabilityTraversal.callable_const_class
    assert_equal sc.const_get(:RequestCallable), RactorRailsShim::ShareabilityTraversal.request_callable_class
    assert_equal RactorRailsShim::SSL_LOC, RactorRailsShim::ShareabilityTraversal.ssl_loc
    assert_equal RactorRailsShim::FILES_LOC, RactorRailsShim::ShareabilityTraversal.files_loc
    assert_equal RactorRailsShim::COOKIE_LOC, RactorRailsShim::ShareabilityTraversal.cookie_loc
    assert_equal RactorRailsShim::DEVISE_SCOPE_LOC, RactorRailsShim::ShareabilityTraversal.devise_scope_loc
    assert_equal RactorRailsShim::MAPPER_LOC, RactorRailsShim::ShareabilityTraversal.mapper_loc
  ensure
    RactorRailsShim::ShareabilityTraversal.reset_configuration
  end

  # --- Issue #30: CONTAINER_WALKERS dispatch table ---

  it "CONTAINER_WALKERS has entries for Hash, Array, Set, Struct" do
    t = RactorRailsShim::ShareabilityTraversal
    assert t.const_defined?(:CONTAINER_WALKERS, false), "CONTAINER_WALKERS should exist"
    walkers = t.const_get(:CONTAINER_WALKERS)
    assert_includes walkers.keys, Hash
    assert_includes walkers.keys, Array
    assert_includes walkers.keys, ::Set
    assert_includes walkers.keys, ::Struct
  end

  it "each_ivar_and_child walks Hash entries via CONTAINER_WALKERS" do
    t = RactorRailsShim::ShareabilityTraversal
    h = { a: 1, b: :sym }
    children = []
    t.each_ivar_and_child(h) { |v, iv| children << [v, iv] }
    # Hash yields keys and values
    assert children.any? { |v, _| v == :a }, "should yield Hash key :a"
    assert children.any? { |v, _| v == 1 }, "should yield Hash value 1"
  end

  it "each_ivar_and_child walks Array entries via CONTAINER_WALKERS" do
    t = RactorRailsShim::ShareabilityTraversal
    a = [1, 2, 3]
    children = []
    t.each_ivar_and_child(a) { |v, iv| children << [v, iv] }
    values = children.map(&:first)
    assert_includes values, 1
    assert_includes values, 2
    assert_includes values, 3
  end

  it "each_ivar_and_child walks Set entries via CONTAINER_WALKERS" do
    t = RactorRailsShim::ShareabilityTraversal
    s = Set.new([:x, :y])
    children = []
    t.each_ivar_and_child(s) { |v, iv| children << [v, iv] }
    values = children.map(&:first)
    assert_includes values, :x
    assert_includes values, :y
  end

  it "each_ivar_and_child walks Struct members via CONTAINER_WALKERS" do
    t = RactorRailsShim::ShareabilityTraversal
    klass = Struct.new(:name, :age)
    obj = klass.new("Alice", 30)
    children = []
    t.each_ivar_and_child(obj) { |v, iv| children << [v, iv] }
    values = children.map(&:first)
    assert_includes values, "Alice"
    assert_includes values, 30
  end

  it "each_ivar_and_child walks custom Enumerable via fallback" do
    t = RactorRailsShim::ShareabilityTraversal
    custom = Class.new do
      include Enumerable
      def each(&b)
        yield :from_custom
        yield :also_custom
      end
    end.new
    children = []
    t.each_ivar_and_child(custom) { |v, iv| children << [v, iv] }
    values = children.map(&:first)
    assert_includes values, :from_custom
    assert_includes values, :also_custom
  end

  it "each_ivar_and_child walks Hash default_proc" do
    t = RactorRailsShim::ShareabilityTraversal
    h = Hash.new { |h, k| h[k] = :default }
    children = []
    t.each_ivar_and_child(h) { |v, iv| children << [v, iv] }
    dp_entries = children.select { |_, iv| iv == :__default_proc__ }
    assert_equal 1, dp_entries.size, "should yield exactly one default_proc entry"
    assert dp_entries.first.first.is_a?(Proc), "default_proc entry should be a Proc"
  end
end