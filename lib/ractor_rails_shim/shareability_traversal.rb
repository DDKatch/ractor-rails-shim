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
# StrategyCall) and the LOC constants (SSL_LOC, FILES_LOC, COOKIE_LOC,
# DEVISE_SCOPE_LOC, MAPPER_LOC) through the configure seam, defaulting to
# the facade lookups so existing call sites keep working (Issue #23,
# POODR §2 Dependencies). Issue #25 will group the constants into a
# Registry; until then they're flat kwargs on the seam.
#
# The RactorRailsShim singleton keeps facade methods that delegate, so
# make_shareable_spec and the integration spec keep passing unchanged.

module RactorRailsShim
  module ShareabilityTraversal
    @funnel = nil
    @find_files_server = nil
    @devise_mapping_replacement = nil
    @strategy_replacement_for = nil
    @noop_lock_class = nil
    @noop_proc_class = nil
    @callable_class = nil
    @callable_const_class = nil
    @request_callable_class = nil
    @locs = nil

    # Value object grouping the 5 LOC strings used to identify which
    # source file a Proc came from during proc-replacement dispatch
    # (Issue #39, POODR §4c). The `configure` seam accepts a single
    # `locs:` kwarg instead of 5 string kwargs; the 5 individual readers
    # (`ssl_loc` etc.) delegate to the Locs object for backward compat.
    Locs = Struct.new(:ssl, :files, :cookie, :devise_scope, :mapper,
                       keyword_init: true) do
      def self.default
        new(
          ssl: RactorRailsShim::SSL_LOC,
          files: RactorRailsShim::FILES_LOC,
          cookie: RactorRailsShim::COOKIE_LOC,
          devise_scope: RactorRailsShim::DEVISE_SCOPE_LOC,
          mapper: RactorRailsShim::MAPPER_LOC,
        )
      end
    end

    # Inject the collaborators. Callables: `funnel` (= _swallow),
    # `find_files_server`, `devise_mapping_replacement`,
    # `strategy_replacement_for`. Callable classes: `noop_lock_class`,
    # `noop_proc_class`, `callable_class`, `callable_const_class`,
    # `request_callable_class`. LOC strings: `locs:` (a `Locs` value
    # object). Passing `nil` for any (or calling `reset_configuration`)
    # restores the facade-lookup default for that collaborator.
    def self.configure(funnel: nil, find_files_server: nil,
                       devise_mapping_replacement: nil, strategy_replacement_for: nil,
                       noop_lock_class: nil, noop_proc_class: nil,
                       callable_class: nil, callable_const_class: nil,
                       request_callable_class: nil,
                       locs: nil)
      @funnel = funnel
      @find_files_server = find_files_server
      @devise_mapping_replacement = devise_mapping_replacement
      @strategy_replacement_for = strategy_replacement_for
      @noop_lock_class = noop_lock_class
      @noop_proc_class = noop_proc_class
      @callable_class = callable_class
      @callable_const_class = callable_const_class
      @request_callable_class = request_callable_class
      @locs = locs
    end

    # Restore the default (facade-lookup) collaborators. Test seam.
    def self.reset_configuration
      @funnel = nil
      @find_files_server = nil
      @devise_mapping_replacement = nil
      @strategy_replacement_for = nil
      @noop_lock_class = nil
      @noop_proc_class = nil
      @callable_class = nil
      @callable_const_class = nil
      @request_callable_class = nil
      @locs = nil
    end

    def self.funnel
      @funnel || RactorRailsShim::Funnel.method(:swallow)
    end

    def self.find_files_server
      @find_files_server || RactorRailsShim.method(:_find_files_server)
    end

    def self.devise_mapping_replacement
      @devise_mapping_replacement || RactorRailsShim.method(:_devise_mapping_replacement)
    end

    def self.strategy_replacement_for
      @strategy_replacement_for || RactorRailsShim::ActionDispatchStrategy.method(:replacement_for)
    end

    def self.noop_lock_class
      @noop_lock_class || RactorRailsShim.singleton_class.const_get(:NoOpLock)
    end

    def self.noop_proc_class
      @noop_proc_class || RactorRailsShim.singleton_class.const_get(:NoOpProc)
    end

    def self.callable_class
      @callable_class || RactorRailsShim.singleton_class.const_get(:Callable)
    end

    def self.callable_const_class
      @callable_const_class || RactorRailsShim.singleton_class.const_get(:CallableConst)
    end

    def self.request_callable_class
      @request_callable_class || RactorRailsShim.singleton_class.const_get(:RequestCallable)
    end

    # The active Locs value object. Delegates the 5 individual LOC
    # readers to the Locs attributes for backward compat.
    def self.locs
      @locs || Locs.default
    end

    def self.ssl_loc; locs.ssl; end
    def self.files_loc; locs.files; end
    def self.cookie_loc; locs.cookie; end
    def self.devise_scope_loc; locs.devise_scope; end
    def self.mapper_loc; locs.mapper; end

    # Container dispatch table: maps container class to a walker lambda.
    # Replaces the is_a? chain in each_ivar_and_child (Issue #30, POODR §4a
    # Duck Typing). Each lambda takes an object and a block, yielding
    # [child, ivar_or_nil] pairs.
    CONTAINER_WALKERS = {
      Hash => ->(o, &b) {
        o.each { |k, v| b.call(k, nil); b.call(v, nil) }
        dp = o.default_proc
        b.call(dp, :__default_proc__) if dp
      },
      Array => ->(o, &b) { o.each { |e| b.call(e, nil) } },
      Set => ->(o, &b) { o.each { |e| b.call(e, nil) } },
      Struct => ->(o, &b) { o.each_pair { |_n, v| b.call(v, nil) } },
    }.freeze

    # BasicObject (and its subclasses) don't define respond_to?, so calling
    # o.respond_to? on one raises NoMethodError. Use this to safely test
    # whether an object can be introspected (is_a?, instance_variables, ...).
    def self.introspectable?(o)
      o.respond_to?(:is_a?)
    rescue NoMethodError
      false
    end

    # The container types with dedicated walkers in CONTAINER_WALKERS,
    # plus String (which is Enumerable over chars but not a container of
    # references we want to walk). Derived from CONTAINER_WALKERS.keys so
    # a new container added to the dispatch table is automatically
    # excluded here — the two lists can't drift (Issue #39, POODR §4a).
    BASIC_TYPES = (CONTAINER_WALKERS.keys + [::String]).freeze

    # True if `o` is Enumerable but NOT one of the container types with a
    # dedicated branch in each_ivar_and_child. Used to gate the generic
    # Enumerable fallback so we don't double-walk Array/Hash/etc.
    def self.enumerable_but_not_basic?(o)
      return false unless o.is_a?(::Enumerable)
      BASIC_TYPES.none? { |t| o.is_a?(t) }
    rescue NoMethodError
      # BasicObject without Kernel — not Enumerable.
      false
    end

    # Enumerate the instance variables of `o`, yielding `[ivar, value]`
    # pairs. The instance_variable_get is guarded so an ivar that raises
    # is skipped (not fatal). The whole instance_variables call is guarded
    # so a BasicObject (or frozen object) that doesn't support it is a
    # no-op. This is the ivar-only half of `each_ivar_and_child` — the
    # half callers that don't need the container walk (e.g.
    # LoggerIONeutralizer, which keeps its per-ivar branching inline)
    # use this directly (Issue #39, POODR §4b Duck Typing).
    def self.each_ivar(o)
      return to_enum(:each_ivar, o) unless block_given?
      begin
        o.instance_variables.each do |iv|
          v =
            begin
              o.instance_variable_get(iv)
            rescue StandardError
              next
            end
          yield iv, v
        end
      rescue StandardError
        # BasicObject or frozen objects don't support instance_variables.
      end
    end

    # Enumerate every child reference of `o` for the graph traversals:
    #   - instance variables (yields [value, iv])
    #   - container entries via CONTAINER_WALKERS (Array, Hash, Set, Struct)
    #   - Enumerable fallback for other Enumerable types
    #
    # Centralized so collect_procs and replace_locks_and_concurrent_maps!
    # share the same container coverage. The ivar half delegates to
    # `each_ivar` (Issue #39) so the rescue scaffolding has one home.
    def self.each_ivar_and_child(o)
      each_ivar(o) { |iv, v| yield v, iv }
      walker = CONTAINER_WALKERS.find { |klass, _| o.is_a?(klass) }&.last
      if walker
        walker.call(o) { |c, iv| yield c, iv }
      elsif enumerable_but_not_basic?(o)
        o.each { |e| yield e, nil } rescue nil
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

    # Proc-replacement dispatch table (Issue #39, POODR §4c Duck Typing).
    # Replaces the 6-way if/elsif on `(source_location_suffix, ivar)` in
    # `replace_one_proc`. Each entry is keyed by `[tag, ivar]` where `tag`
    # is a Symbol identifying the LOC string (resolved at dispatch time
    # via `src.end_with?`, so injected LOCs work) and `ivar` is the ivar
    # symbol or `nil` for an ivar-wildcard (matches any ivar). The `[nil,
    # nil]` entry is the default for unknown Procs. Each value is a
    # lambda `(traversal, proc_obj, parent, mw) -> replacement`. Adding a
    # new proc-replacement rule is a one-line table entry instead of a
    # new `elsif`.
    PROC_REPLACEMENTS = {
      [:ssl, :@exclude] => ->(t, _p, parent, _mw) {
        t.callable_const_class.new(!parent.instance_variable_get(:@redirect))
      },
      [:files, :@app] => ->(t, proc_obj, parent, mw) {
        # The lambda is `Rack::Files#initialize`'s `lambda { |env| get env }`,
        # stored as `Rack::Head#@app`. Its `self` (binding receiver) is the
        # `Rack::Files` instance that defines `get` — NOT the `Rack::Head`
        # that holds it. Use the binding receiver as the callable target so
        # the worker calls `Rack::Files#get(env)` (the original behavior).
        # Fall back to the middleware-chain search if the receiver can't be
        # resolved (e.g. frozen/unavailable binding).
        receiver = proc_obj.binding.receiver rescue nil
        files_server = receiver if receiver && receiver.respond_to?(:get)
        files_server ||= t.find_files_server.call(mw)
        files_server ||= parent
        t.callable_class.new(files_server, :get)
      },
      [:cookie, nil] => ->(t, _p, _parent, _mw) {
        t.request_callable_class.new(:cookies_same_site_protection)
      },
      [:devise_scope, nil] => ->(t, proc_obj, parent, _mw) {
        t.devise_mapping_replacement.call(proc_obj, parent)
      },
      [:mapper, :@strategy] => ->(t, proc_obj, _parent, _mw) {
        # Identify SERVE vs CALL by OBJECT IDENTITY against the actual
        # ActionDispatch constants, NOT by source_location line number.
        # See strategy_replacement_for for the full rationale.
        t.strategy_replacement_for.call(proc_obj)
      },
      [nil, nil] => ->(t, _p, _parent, _mw) {
        t.noop_proc_class.new
      },
    }.freeze

    # The ordered list of (tag, locs-attr) pairs used to resolve a
    # source_location suffix to a tag. Kept in dispatch order (the first
    # matching suffix wins, mirroring the original elsif chain). The
    # `[nil, nil]` default in PROC_REPLACEMENTS is the fallback.
    LOC_TAGS = [
      [:ssl,          :ssl],
      [:files,        :files],
      [:cookie,       :cookie],
      [:devise_scope, :devise_scope],
      [:mapper,       :mapper],
    ].freeze

    # Resolve a source_location suffix to a LOC tag, or nil if no LOC
    # matches. Drives the PROC_REPLACEMENTS lookup.
    def self.loc_tag_for(src)
      current_locs = locs
      LOC_TAGS.each do |tag, attr|
        return tag if src.end_with?(current_locs.public_send(attr))
      end
      nil
    end

    def self.replace_one_proc(proc_obj, parent, ivar, mw)
      src = proc_obj.source_location&.first || ""
      tag = loc_tag_for(src)
      key = PROC_REPLACEMENTS.key?([tag, ivar]) ? [tag, ivar] : [tag, nil]
      builder = PROC_REPLACEMENTS.fetch(key) { PROC_REPLACEMENTS[[nil, nil]] }
      replacement = builder.call(self, proc_obj, parent, mw)

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
        funnel.call("replace proc ivar") do
          parent.instance_variable_set(ivar, replacement)
        end
      elsif parent.is_a?(Array)
        idx = parent.index(proc_obj)
        if idx then parent[idx] = replacement
        else parent.each_with_index { |e, i| parent[i] = replacement if e.equal?(proc_obj) }
        end
      elsif parent.is_a?(Hash)
        funnel.call("replace proc hash entry") do
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
            funnel.call("replace lock ivar") do
              o.instance_variable_set(child_ivar, noop_lock_class.new) if child_ivar
            end
            # If the lock is in an Array/Set/Hash (no ivar), we can't swap
            # it in place here — leave it; make_shareable will handle the
            # frozen container. The ivar case is the load-bearing one.
          elsif defined?(::Concurrent::Map) && child.is_a?(::Concurrent::Map) && child_ivar
            hash_copy = {}
            child.each_pair { |k, val| hash_copy[k] = val }
            funnel.call("replace concurrent map ivar") do
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
      ARModelWalker.each_model do |klass|
        next unless klass.respond_to?(:define_attribute_methods)
        klass.define_attribute_methods
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
      ARModelWalker.each_model do |klass|
        next unless klass.respond_to?(:attribute_method_patterns_cache, true)
        cache = klass.send(:attribute_method_patterns_cache)
        cache.freeze if cache
        if klass.respond_to?(:attribute_method_matchers, true)
          matchers = klass.send(:attribute_method_matchers)
          matchers.freeze if matchers
        end
      end
    end
  end
end