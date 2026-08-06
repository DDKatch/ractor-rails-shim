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
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
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

  it "configure injects the LOC-string collaborators via locs:" do
    t = RactorRailsShim::ShareabilityTraversal
    locs = t::Locs.new(ssl: "/x/ssl.rb", files: "/x/files.rb",
                       cookie: "/x/cookie.rb", devise_scope: "/x/devise.rb",
                       mapper: "/x/mapper.rb")
    t.configure(locs: locs)
    assert_equal "/x/ssl.rb", t.ssl_loc
    assert_equal "/x/files.rb", t.files_loc
    assert_equal "/x/cookie.rb", t.cookie_loc
    assert_equal "/x/devise.rb", t.devise_scope_loc
    assert_equal "/x/mapper.rb", t.mapper_loc
  ensure
    t.reset_configuration
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
    t = RactorRailsShim::ShareabilityTraversal
    locs = t::Locs.new(ssl: "a", files: "b", cookie: "c",
                       devise_scope: "d", mapper: "e")
    t.configure(
      funnel: ->(label, &blk) { blk&.call },
      find_files_server: ->(mw) { },
      devise_mapping_replacement: ->(p, pr) { },
      strategy_replacement_for: ->(p) { },
      noop_lock_class: Class.new, noop_proc_class: Class.new,
      callable_class: Class.new, callable_const_class: Class.new,
      request_callable_class: Class.new,
      locs: locs
    )
    refute_equal RactorRailsShim::Funnel.method(:swallow), t.funnel
    refute_equal RactorRailsShim.method(:_find_files_server), t.find_files_server

    t.reset_configuration
    assert_equal RactorRailsShim::Funnel.method(:swallow), t.funnel
    assert_equal RactorRailsShim.method(:_find_files_server), t.find_files_server
    assert_equal RactorRailsShim.method(:_devise_mapping_replacement), t.devise_mapping_replacement
    assert_equal RactorRailsShim::ActionDispatchStrategy.method(:replacement_for), t.strategy_replacement_for
    assert_equal sc.const_get(:NoOpLock), t.noop_lock_class
    assert_equal sc.const_get(:NoOpProc), t.noop_proc_class
    assert_equal sc.const_get(:Callable), t.callable_class
    assert_equal sc.const_get(:CallableConst), t.callable_const_class
    assert_equal sc.const_get(:RequestCallable), t.request_callable_class
    assert_equal RactorRailsShim::SSL_LOC, t.ssl_loc
    assert_equal RactorRailsShim::FILES_LOC, t.files_loc
    assert_equal RactorRailsShim::COOKIE_LOC, t.cookie_loc
    assert_equal RactorRailsShim::DEVISE_SCOPE_LOC, t.devise_scope_loc
    assert_equal RactorRailsShim::MAPPER_LOC, t.mapper_loc
  ensure
    t.reset_configuration
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

  # --- Issue #39: ShareabilityTraversal polymorphism ---
  #
  # Step 39.1: each_ivar — the ivar-only half of each_ivar_and_child, the
  # half LoggerIONeutralizer needs (it walks only ivars, not container
  # children, and currently duplicates the rescue-scaffolded ivar loop).
  # Step 39.3: enumerable_but_not_basic? derived from CONTAINER_WALKERS
  # keys + String, so a new container walker is automatically excluded.
  # Step 39.4: PROC_REPLACEMENTS table drives replace_one_proc dispatch.

  it "each_ivar yields [ivar, value] pairs for each instance variable" do
    t = RactorRailsShim::ShareabilityTraversal
    o = Object.new
    o.instance_variable_set(:@a, 1)
    o.instance_variable_set(:@b, :two)
    pairs = []
    t.each_ivar(o) { |iv, v| pairs << [iv, v] }
    assert_includes pairs, [:@a, 1]
    assert_includes pairs, [:@b, :two]
  end

  it "each_ivar yields nothing for an object with no ivars" do
    t = RactorRailsShim::ShareabilityTraversal
    pairs = []
    t.each_ivar(Object.new) { |iv, v| pairs << [iv, v] }
    assert_empty pairs
  end

  it "each_ivar skips ivars whose instance_variable_get raises" do
    t = RactorRailsShim::ShareabilityTraversal
    # A frozen object with a ivar that raises on get (simulate via a
    # class overriding instance_variable_get).
    kl = Class.new do
      def initialize; @ok = 1; @bad = 2; end
      def instance_variable_get(name)
        raise StandardError if name == :@bad
        super
      end
    end
    o = kl.new
    pairs = []
    t.each_ivar(o) { |iv, v| pairs << [iv, v] }
    assert_includes pairs, [:@ok, 1]
    refute_includes pairs.map(&:first), :@bad
  end

  it "each_ivar returns an Enumerator when no block is given" do
    t = RactorRailsShim::ShareabilityTraversal
    o = Object.new
    o.instance_variable_set(:@a, 1)
    enum = t.each_ivar(o)
    assert_kind_of Enumerator, enum
    assert_includes enum.to_a, [:@a, 1]
  end

  it "each_ivar rescues when instance_variables itself raises (BasicObject)" do
    t = RactorRailsShim::ShareabilityTraversal
    basic = Class.new(BasicObject) do
      def instance_variables; raise StandardError; end
    end.new
    pairs = []
    t.each_ivar(basic) { |iv, v| pairs << [iv, v] }
    assert_empty pairs
  end

  it "enumerable_but_not_basic? excludes every type in CONTAINER_WALKERS plus String" do
    t = RactorRailsShim::ShareabilityTraversal
    excluded = t::CONTAINER_WALKERS.keys + [String]
    excluded.each do |klass|
      instance = case klass
                 when String then "x"
                 when Struct then Struct.new(:a).new
                 when Set then Set.new
                 when Hash then {}
                 when Array then []
                 else klass.new
                 end
      refute t.enumerable_but_not_basic?(instance),
             "#{klass} is in CONTAINER_WALKERS (or String) and must be excluded"
    end
  end

  it "PROC_REPLACEMENTS is a frozen lookup table" do
    t = RactorRailsShim::ShareabilityTraversal
    assert t.const_defined?(:PROC_REPLACEMENTS, false), "PROC_REPLACEMENTS should exist"
    table = t.const_get(:PROC_REPLACEMENTS)
    assert table.frozen?, "PROC_REPLACEMENTS must be frozen"
    assert_kind_of Hash, table
  end

  it "PROC_REPLACEMENTS dispatches [:ssl, :@exclude] to a callable" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [:ssl, :@exclude]
    assert table.key?(key), "PROC_REPLACEMENTS should key [:ssl, :@exclude]"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS dispatches [:files, :@app] to a callable" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [:files, :@app]
    assert table.key?(key), "PROC_REPLACEMENTS should key [:files, :@app]"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS dispatches :cookie for any ivar (nil wildcard)" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [:cookie, nil]
    assert table.key?(key), "PROC_REPLACEMENTS should key [:cookie, nil] (ivar wildcard)"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS dispatches :devise_scope for any ivar (nil wildcard)" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [:devise_scope, nil]
    assert table.key?(key), "PROC_REPLACEMENTS should key [:devise_scope, nil]"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS dispatches [:mapper, :@strategy] to a callable" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [:mapper, :@strategy]
    assert table.key?(key), "PROC_REPLACEMENTS should key [:mapper, :@strategy]"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS falls back to the default entry [nil, nil] for unknown procs" do
    t = RactorRailsShim::ShareabilityTraversal
    table = t::PROC_REPLACEMENTS
    key = [nil, nil]
    assert table.key?(key), "PROC_REPLACEMENTS should have a [nil, nil] default entry"
    assert_respond_to table[key], :call
  end

  it "PROC_REPLACEMENTS drives replace_one_proc for the ssl branch" do
    t = RactorRailsShim::ShareabilityTraversal
    # A Proc whose source_location ends with ssl_loc and ivar :@exclude
    # should get the CallableConst replacement, not NoOpProc.
    callable_const_class = Class.new { def initialize(_arg); end }
    t.configure(
      callable_const_class: callable_const_class,
      funnel: ->(label, &blk) { blk&.call rescue StandardError; }
    )
    parent = Object.new
    parent.instance_variable_set(:@redirect, false)
    ssl_proc = eval("lambda { }", TOPLEVEL_BINDING, t.ssl_loc, 1)
    t.replace_one_proc(ssl_proc, parent, :@exclude, nil)
    assert_kind_of callable_const_class, parent.instance_variable_get(:@exclude)
  ensure
    t.reset_configuration
  end

  it "PROC_REPLACEMENTS drives replace_one_proc for unknown src → NoOpProc default" do
    t = RactorRailsShim::ShareabilityTraversal
    noop_proc_class = Class.new
    t.configure(
      noop_proc_class: noop_proc_class,
      funnel: ->(label, &blk) { blk&.call rescue StandardError; }
    )
    parent = Object.new
    unknown_proc = eval("lambda { }", TOPLEVEL_BINDING, "/some/unknown/file.rb", 1)
    t.replace_one_proc(unknown_proc, parent, :@whatever, nil)
    assert_kind_of noop_proc_class, parent.instance_variable_get(:@whatever)
  ensure
    t.reset_configuration
  end

  # --- Step 39.5: Locs value object ---
  #
  # The 5 LOC strings (ssl_loc, files_loc, cookie_loc, devise_scope_loc,
  # mapper_loc) are grouped into a single Locs value object. configure
  # takes a `locs:` kwarg instead of 5 string kwargs. The 5 individual
  # readers remain as delegations to the Locs object for backward compat.

  it "Locs is a Data/Struct-like value object with ssl, files, cookie, devise_scope, mapper" do
    t = RactorRailsShim::ShareabilityTraversal
    assert t.const_defined?(:Locs, false), "Locs should exist"
    locs = t::Locs.new(ssl: "s", files: "f", cookie: "c", devise_scope: "d", mapper: "m")
    assert_equal "s", locs.ssl
    assert_equal "f", locs.files
    assert_equal "c", locs.cookie
    assert_equal "d", locs.devise_scope
    assert_equal "m", locs.mapper
  end

  it "Locs.default returns the facade-lookup LOC strings" do
    t = RactorRailsShim::ShareabilityTraversal
    locs = t::Locs.default
    assert_equal RactorRailsShim::SSL_LOC, locs.ssl
    assert_equal RactorRailsShim::FILES_LOC, locs.files
    assert_equal RactorRailsShim::COOKIE_LOC, locs.cookie
    assert_equal RactorRailsShim::DEVISE_SCOPE_LOC, locs.devise_scope
    assert_equal RactorRailsShim::MAPPER_LOC, locs.mapper
  end

  it "configure accepts a locs: kwarg (Locs value object)" do
    t = RactorRailsShim::ShareabilityTraversal
    locs = t::Locs.new(ssl: "/x/ssl.rb", files: "/x/files.rb",
                       cookie: "/x/cookie.rb", devise_scope: "/x/ds.rb",
                       mapper: "/x/mapper.rb")
    t.configure(locs: locs)
    assert_equal "/x/ssl.rb", t.ssl_loc
    assert_equal "/x/files.rb", t.files_loc
    assert_equal "/x/cookie.rb", t.cookie_loc
    assert_equal "/x/ds.rb", t.devise_scope_loc
    assert_equal "/x/mapper.rb", t.mapper_loc
  ensure
    t.reset_configuration
  end

  it "configure no longer accepts the 5 individual LOC kwargs" do
    t = RactorRailsShim::ShareabilityTraversal
    # The 5 individual kwargs are gone; only locs: is accepted.
    # Passing ssl_loc: should raise ArgumentError (unknown kwarg).
    assert_raises(ArgumentError) do
      t.configure(ssl_loc: "/x/ssl.rb")
    end
  ensure
    t.reset_configuration
  end

  it "reset_configuration restores the default Locs" do
    t = RactorRailsShim::ShareabilityTraversal
    t.configure(locs: t::Locs.new(ssl: "a", files: "b", cookie: "c",
                                    devise_scope: "d", mapper: "e"))
    refute_equal RactorRailsShim::SSL_LOC, t.ssl_loc
    t.reset_configuration
    assert_equal RactorRailsShim::SSL_LOC, t.ssl_loc
    assert_equal RactorRailsShim::FILES_LOC, t.files_loc
    assert_equal RactorRailsShim::COOKIE_LOC, t.cookie_loc
    assert_equal RactorRailsShim::DEVISE_SCOPE_LOC, t.devise_scope_loc
    assert_equal RactorRailsShim::MAPPER_LOC, t.mapper_loc
  ensure
    t.reset_configuration
  end

  it "locs reader returns the active Locs object" do
    t = RactorRailsShim::ShareabilityTraversal
    assert_kind_of t::Locs, t.locs
    assert_equal RactorRailsShim::SSL_LOC, t.locs.ssl
  ensure
    t.reset_configuration
  end
end