# frozen_string_literal: true

# ShareabilityTraversal: the app-graph traversal role extracted from the
# RactorRailsShim god module (Issue #13, Step 13.2; POODR §1 SRP).
#
# Owns the graph-walking machinery used by make_app_shareable! to replace
# unshareable values in the app object graph:
#   - introspectable?(o)                 BasicObject-safe respond_to? guard
#   - collect_procs(app)                 gather every Proc in the graph
#   - replace_unshareable_procs!(app)    multi-pass Proc → callable swap
#   - replace_one_proc(...)              per-Proc replacement dispatch
#   - replace_locks_and_concurrent_maps! Mutex/Monitor → NoOpLock,
#                                        Concurrent::Map → Hash
#   - each_ivar_and_child(o)             unified container enumerator
#   - enumerable_but_not_basic?(o)        Enumerable-fallback gate
#   - precompute_lazy_ivars(app)         force lazy app ivars to populate
#   - generate_ar_attribute_methods!     force AR attribute-method generation
#   - warm_attribute_method_patterns!    freeze ActiveModel method caches
#
# The per-Proc replacement dispatch reaches cross-concern helpers
# (_find_files_server in rack.rb, _devise_mapping_replacement in warden.rb,
# _strategy_replacement_for here-adjacent) and the callable classes
# (NoOpProc, Callable, CallableConst, RequestCallable, StrategyServe,
# StrategyCall) through the RactorRailsShim facade — matching the Freezers::*
# and ConstantShareabilizer pattern. The LOC constants (SSL_LOC, FILES_LOC,
# COOKIE_LOC, DEVISE_SCOPE_LOC, MAPPER_LOC) live on RactorRailsShim and are
# read via the facade.
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# make_shareable_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module ShareabilityTraversal
    # BasicObject (and its subclasses) don't define respond_to?, so calling
    # o.respond_to? on one raises NoMethodError. Use this to safely test
    # whether an object can be introspected (is_a?, instance_variables, ...).
    def self.introspectable?(o)
      o.respond_to?(:is_a?)
    rescue NoMethodError
      false
    end

    # True if `o` is Enumerable but NOT one of the container types with a
    # dedicated branch in each_ivar_and_child. Used to gate the generic
    # Enumerable fallback so we don't double-walk Array/Hash/etc.
    def self.enumerable_but_not_basic?(o)
      return false unless o.is_a?(::Enumerable)
      return false if o.is_a?(::Array) || o.is_a?(::Hash) || o.is_a?(::Set) || o.is_a?(::Struct)
      return false if o.is_a?(::String) # String is Enumerable (chars) but not a container of refs we want
      true
    rescue NoMethodError
      # BasicObject without Kernel — not Enumerable.
      false
    end

    # Enumerate every child reference of `o` for the graph traversals:
    #   - instance variables (yields [value, iv])
    #   - Array / Set / Enumerable members (yields [member, nil])
    #   - Hash pairs (yields [key, nil] and [val, nil])
    #   - Hash#default_proc (yields [proc, :__default_proc__])
    #   - Struct members (yields [value, nil] via #each_pair)
    #
    # Centralized so collect_procs and replace_locks_and_concurrent_maps!
    # share the same container coverage (Array, Hash, Set, Struct).
    def self.each_ivar_and_child(o)
      begin
        o.instance_variables.each do |iv|
          begin; v = o.instance_variable_get(iv); rescue StandardError; next; end
          yield v, iv
        end
      rescue StandardError => e
        # BasicObject or frozen objects don't support instance_variables
      end
      if o.is_a?(Hash)
        o.each do |k, val|
          yield k, nil
          yield val, nil
        end
        dp = o.default_proc
        yield dp, :__default_proc__ if dp
      elsif o.is_a?(Array)
        o.each_with_index { |e, i| yield e, nil }
      elsif o.is_a?(::Set)
        o.each_with_index { |e, i| yield e, nil }
      elsif o.is_a?(::Struct)
        o.each_pair { |name, val| yield val, nil }
      elsif enumerable_but_not_basic?(o)
        # Generic Enumerable fallback (Range, Enumerator, custom Enumerable
        # mixes). Skip String/Hash/Array/Set/Struct — already handled. Best
        # effort; rescue per-element in case #each raises for some members.
        o.each do |e|
          yield e, nil
        end rescue nil
      end
    end

    def self.collect_procs(app)
      seen = {}
      procs = []
      stack = [[app, nil, nil]]
      until stack.empty?
        o, parent, ivar = stack.pop
        next if o.equal?(nil)
        # Skip BasicObject subclasses that don't respond to is_a?/object_id
        # (e.g. ActiveSupport::Callbacks::CallTemplate internals). Must guard
        # BEFORE calling is_a? — BasicObject doesn't define it.
        next unless introspectable?(o)
        if o.is_a?(Proc)
          procs << [o, parent, ivar]
          next
        end
        next if seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
        each_ivar_and_child(o) do |child, child_ivar|
          if child_ivar == :__default_proc__
            procs << [child, o, :__default_proc__]
          else
            stack << [child, o, child_ivar] if child
          end
        end
      end
      procs
    end

    # Replace every Proc in the app graph with a callable/no-op object.
    # Multiple passes because the same Proc object can live in many
    # containers (e.g. deprecation behaviors shared across deprecators).
    # Doesn't dedup procs — must replace every occurrence.
    def self.replace_unshareable_procs!(app)
      mw = (app.instance_variable_get(:@app) rescue nil)
      # Replace every Proc in the graph. The same Proc object can live in
      # many containers (e.g. deprecation behaviors shared across
      # deprecators), and replacing one occurrence doesn't replace the
      # others — so we loop until a fixed point (no Procs left). A safety
      # cap guards against a pathological graph where replacement keeps
      # introducing new Procs (the replacements themselves are NoOpProc/
      # Callable instances, not Procs, so this shouldn't happen, but the
      # cap prevents an infinite loop if a future callable class leaks a
      # Proc). 3 passes was the original magic number; observed real graphs
      # converge in 2.
      max_passes = 8
      max_passes.times do
        procs = collect_procs(app)
        break if procs.empty?
        procs.each { |proc_obj, parent, ivar| replace_one_proc(proc_obj, parent, ivar, mw) }
      end
    end

    def self.replace_one_proc(proc_obj, parent, ivar, mw)
      sc = RactorRailsShim.singleton_class
      src = proc_obj.source_location&.first || ""
      replacement =
        if src.end_with?(RactorRailsShim::SSL_LOC) && ivar == :@exclude
          redirect = parent.instance_variable_get(:@redirect)
          sc.const_get(:CallableConst).new(!redirect)
        elsif src.end_with?(RactorRailsShim::FILES_LOC) && ivar == :@app
          # The lambda is `Rack::Files#initialize`'s `lambda { |env| get env }`,
          # stored as `Rack::Head#@app`. Its `self` (binding receiver) is the
          # `Rack::Files` instance that defines `get` — NOT the `Rack::Head`
          # that holds it. Use the binding receiver as the callable target so
          # the worker calls `Rack::Files#get(env)` (the original behavior).
          # Fall back to the middleware-chain search if the receiver can't be
          # resolved (e.g. frozen/unavailable binding).
          receiver = proc_obj.binding.receiver rescue nil
          files_server = receiver if receiver && receiver.respond_to?(:get)
          files_server ||= RactorRailsShim._find_files_server(mw)
          files_server ||= parent
          sc.const_get(:Callable).new(files_server, :get)
        elsif src.end_with?(RactorRailsShim::COOKIE_LOC)
          sc.const_get(:RequestCallable).new(:cookies_same_site_protection)
        elsif src.end_with?(RactorRailsShim::DEVISE_SCOPE_LOC)
          RactorRailsShim._devise_mapping_replacement(proc_obj, parent)
        elsif src.end_with?(RactorRailsShim::MAPPER_LOC) && ivar == :@strategy
          # Identify SERVE vs CALL by OBJECT IDENTITY against the actual
          # ActionDispatch constants, NOT by source_location line number.
          # See _strategy_replacement_for for the full rationale.
          RactorRailsShim._strategy_replacement_for(proc_obj)
        else
          sc.const_get(:NoOpProc).new
        end

      if ivar == :__default_proc__
        # The parent Hash may already be frozen (e.g. by an earlier
        # shareability pass on AR internals). A frozen Hash can't have its
        # default cleared, but a frozen Hash with a default_proc is still
        # unshareable — Ractor.make_shareable(parent) later will replace it
        # wholesale if needed. Just skip here when frozen.
        begin
          parent.default = nil
        rescue FrozenError, RuntimeError
          # frozen Hash — leave the default_proc; make_shareable handles it.
        end
      elsif ivar
        RactorRailsShim._swallow("replace proc ivar") do
          parent.instance_variable_set(ivar, replacement)
        end
      elsif parent.is_a?(Array)
        idx = parent.index(proc_obj)
        if idx then parent[idx] = replacement
        else parent.each_with_index { |e, i| parent[i] = replacement if e.equal?(proc_obj) }
        end
      elsif parent.is_a?(Hash)
        RactorRailsShim._swallow("replace proc hash entry") do
          key = parent.key(proc_obj)
          parent[key] = replacement if key
        end
      end
    end

    # NOTE: `_devise_mapping_replacement` (Devise scope constraint →
    # DeviseMappingCallable) now lives in warden.rb; `_find_files_server`
    # (Rack::Files target for the asset stack) now lives in rack.rb.

    # Identify which ActionDispatch strategy a Proc is and return its
    # shareable replacement. The Proc stored in
    # `ActionDispatch::Routing::Mapper::Constraints#@strategy` is the
    # constant `SERVE` or `CALL` (assigned by reference), so `equal?` is the
    # robust identifier — independent of the source line number, which
    # any Rails patch release can shift. Returns NoOpProc for an unknown
    # Proc (defensive; never mis-route).
    #
    # Kept on the facade (not moved here) because it constructs
    # StrategyServe/StrategyCall (action_dispatch.rb concern) — it's a
    # cross-concern dispatcher reached via RactorRailsShim._strategy_replacement_for.
    # The extracted traversal calls it through the facade.

    def self.replace_locks_and_concurrent_maps!(app)
      seen = {}
      stack = [[app, nil, nil]]
      until stack.empty?
        o, _parent, _ivar = stack.pop
        next if o.equal?(nil)
        next unless introspectable?(o)
        next if seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
        each_ivar_and_child(o) do |child, child_ivar|
          next if child_ivar == :__default_proc__
          if child.is_a?(Mutex) || child.is_a?(Monitor)
            RactorRailsShim._swallow("replace lock ivar") do
              o.instance_variable_set(child_ivar, RactorRailsShim.singleton_class.const_get(:NoOpLock).new) if child_ivar
            end
            # If the lock is in an Array/Set/Hash (no ivar), we can't swap
            # it in place here — leave it; make_shareable will handle the
            # frozen container. The ivar case is the load-bearing one.
          elsif defined?(::Concurrent::Map) && child.is_a?(::Concurrent::Map) && child_ivar
            hash_copy = {}
            child.each_pair { |k, val| hash_copy[k] = val }
            RactorRailsShim._swallow("replace concurrent map ivar") do
              o.instance_variable_set(child_ivar, hash_copy)
            end
          elsif child
            stack << [child, o, child_ivar]
          end
        end
      end
    end

    # Force lazy app ivars to populate in the MAIN Ractor before the graph
    # is frozen. Each call rescues nil (the app may not define the method,
    # or it may raise during boot).
    def self.precompute_lazy_ivars(app)
      app.env_config
      app.app_env_config rescue nil
      app.routes.url_helpers rescue nil
      app.routes.named_routes rescue nil
      app.routes.helpers rescue nil
    end

    # Force AR attribute-method generation for every loaded model in the
    # MAIN Ractor. See the call site in make_app_shareable! for why; without
    # this a worker Ractor dies with Ractor::IsolationError on the first
    # model instantiation (GeneratedAttributeMethods::LOCK is a
    # non-shareable Monitor).
    def self.generate_ar_attribute_methods!
      return unless defined?(::ActiveRecord::Base)
      ::ActiveRecord::Base.descendants.each do |klass|
        next unless klass.respond_to?(:define_attribute_methods)
        klass.define_attribute_methods
      rescue StandardError
        nil
      end
    end

    # Build + freeze ActiveModel's per-class `attribute_method_patterns_cache`
    # (and `attribute_method_matchers`) in the MAIN Ractor for every loaded
    # model. These are lazy class ivars populated on the first `respond_to?`
    # call; they hold an Array of `[Regexp, Symbol]` pairs (shareable
    # elements) but the Array itself is mutable and therefore NOT
    # Ractor-shareable. A worker Ractor reading the ivar raises
    # `Ractor::IsolationError`. Building it in MAIN (where it is reachable)
    # and freezing the Array makes it shareable; the cache is never mutated
    # after build, so freezing is safe.
    def self.warm_attribute_method_patterns!
      return unless defined?(::ActiveRecord::Base)
      ::ActiveRecord::Base.descendants.each do |klass|
        next unless klass.respond_to?(:attribute_method_patterns_cache, true)
        begin
          cache = klass.send(:attribute_method_patterns_cache)
          cache.freeze if cache
          if klass.respond_to?(:attribute_method_matchers, true)
            matchers = klass.send(:attribute_method_matchers)
            matchers.freeze if matchers
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end