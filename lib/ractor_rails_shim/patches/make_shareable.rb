# frozen_string_literal: true

# make_app_shareable! infrastructure: callable/lock replacement classes,
# graph traversal (collect procs, replace locks/maps), shareable fallback
# builder, and the main make_app_shareable! entry point.

module RactorRailsShim
  class << self
    # Devise defines several mutable module-level constants (Array/Hashes
    # populated at load time: mappings, strategies, url helpers, no_input
    # strategies). Worker Ractors read them (e.g. Devise::NO_INPUT in
    # mapping.rb), so they must be deep-frozen + made shareable before the
    # app graph is frozen. Added here; make_constant_shareable resolves each
    # lazily once Devise is loaded.
    SHAREABLE_CONSTANTS.concat([
      "Devise::ALL",
      "Devise::CONTROLLERS",
      "Devise::ROUTES",
      "Devise::STRATEGIES",
      "Devise::URL_HELPERS",
      "Devise::NO_INPUT",
    ])

    # Class instance variables holding unshareable values that workers read
    # during request dispatch. Made Ractor-shareable (deep-frozen) at boot.
    SHAREABLE_CLASS_IVARS.concat([
      ["ActiveSupport::Editor", :@editors],
      ["Warden::Strategies", :@strategies],
    ])

    # Public API: make Rails.application shareable across Ractors. Replaces
    # every self-capturing Proc in the app graph with a callable object (no
    # captured binding), every Mutex/Monitor with a NoOpLock, and every
    # Concurrent::Map with a frozen Hash, then calls Ractor.make_shareable.
    # After this, `Ractor.new(app) { |a| a.call(env) }` works from worker
    # Ractors. Must run in the main Ractor after prepare_for_ractors! and
    # before spawning workers.
    #
    # WARNING: this MUTATES the app object graph in place (replaces ivars).
    # The app becomes read-only (frozen). Do NOT call if you intend to keep
    # mutating the app (e.g. development reloading). Production-only.
    #
    # Returns the shareable app. Raises on failure (e.g. if a Proc can't be
    # replaced — add the missing constant to shareable_constants first).
    def make_app_shareable!(app = Rails.application)
      # Shareable constants + Rack::Request + Inflector + ParameterEncoding +
      # PathRegistry + AbstractController + error_reporter + LookupContext +
      # I18n + Template::Handlers + ExecutionContext + Request param parsers.
      do_install_shareable_constants unless @shareable_constants_done
      # Install (or re-run, idempotently) the full framework-patch set. Most
      # are already applied by prepare_for_ractors!; this guarantees every
      # patch is present after full boot even if prepare_for_ractors! ran
      # before some classes were loaded.
      _install_all_framework_patches
      # Pre-compute lazy ivars BEFORE freezing (they mutate the app).
      _precompute_lazy_ivars(app)
      _precompute_propshaft!(app)
      # Force ActiveRecord attribute-method generation in the MAIN Ractor for
      # every loaded model. AR defines these lazily on first instantiation; if
      # left undone, a worker Ractor's first `Post.new` / record load re-enters
      # `define_attribute_methods`, which locks
      # `GeneratedAttributeMethods::LOCK` — a `Monitor` created in the main
      # Ractor and therefore non-shareable — raising Ractor::IsolationError.
      # Generating here (where the Monitor is reachable) sets
      # `@attribute_methods_generated = true` on the shared, frozen classes so
      # workers skip the lock entirely.
      _generate_ar_attribute_methods!
      # Warm + freeze ActiveModel's per-class `attribute_method_patterns_cache`
      # (and `attribute_method_matchers`) in MAIN for every loaded model. See
      # `_warm_attribute_method_patterns!` for why: a worker Ractor reading these
      # lazy class ivars (Array of [Regexp, Symbol], but mutable => unshareable)
      # during `redirect_to @post` -> `respond_to?` raises Ractor::IsolationError.
      _warm_attribute_method_patterns!
      # Capture each controller's OWN declared `process_action` symbol filters
      # (before_action / after_action) into a shareable table so worker
      # Ractors can replay them. The shim routes class_attribute-backed
      # `__callbacks` through IES and seeds workers with the empty default, so
      # controller filters do NOT run in workers by default (see
      # execution_wrapper.rb run_callbacks patch). For GET requests that depend
      # on a before_action (e.g. `set_post` loading `@post`), that breaks
      # rendering. We freeze the declared-filter table captured during eager
      # load (in main, before freeze) and the patched run_callbacks replays
      # them per controller.
      _freeze_declared_callbacks!
      # Warm + cache the routes' @ast / @simulator on the live graph. This MUST
      # run AFTER the route precompute above (which reloads/resets the routes)
      # and BEFORE _replace_unshareable_procs! / Ractor.make_shareable below:
      # the proc-replacement pass rewrites the Route constraint Procs held in
      # the simulator's @memos, and the freeze then shares the whole thing so
      # worker Ractors read the cached, frozen simulator via the original
      # Routes#simulator (no per-worker rebuild). See action_dispatch.rb.
      _freeze_shareable_class_ivars!
      _warm_journey_routes!
      # Neutralize the app's logger IO so Ractor.make_shareable doesn't freeze
      # $stdout/$stderr (freezing STDOUT breaks the process's own output).
      # Workers build their own per-Ractor Rails.logger, so the app-instance
      # logger is unused post-freeze; redirect its logdev to a fresh StringIO
      # sink (which is safely freezable).
      _neutralize_logger_io!(app)
      _replace_unshareable_procs!(app)
      _replace_locks_and_concurrent_maps!(app)
      Ractor.make_shareable(app)
      # Stash the now-shareable app in a constant so worker Ractors can read
      # `Rails.application` (e.g. Propshaft::Helper reads
      # `Rails.application.assets`, and various gems call Rails.application
      # internally). The shared app is frozen (read-only), so returning it
      # from worker Ractors is safe — they only read from it, never mutate.
      if Ractor.main?
        verbose, $VERBOSE = $VERBOSE, nil
        begin
          const_set(:SHAREABLE_APP, app) unless const_defined?(:SHAREABLE_APP)
        ensure
          $VERBOSE = verbose
        end
      end
      # Build the framework-config fallback AFTER the app is frozen. The
      # fallback makes class_attribute / mattr_accessor values shareable; some
      # of those values reference the app graph (e.g. config objects that point
      # back at Rails.application). Doing this after the app is already
      # shareable means Ractor.make_shareable on the config values is a no-op
      # for the app portion (already frozen) — avoiding a "can't modify frozen
      # app" error when precompute wrote to it. (prepare_for_ractors!, which
      # also builds the fallback, is a no-op now via @fallback_built.)
      _build_shareable_fallback!
      app
    end

    # Detach the logger IO from the app graph so Ractor.make_shareable(app)
    # doesn't freeze the process's real $stdout/$stderr. The app-instance
    # logger (app.config.logger) holds an IO in its logdev; freezing it would
    # silence main-ractor logging and break minitest/server output.
    #
    # Strategy: replace app.config.logger (and any broadcast target reachable
    # from the app) with a frozen, shareable no-op BroadcastLogger (no IO).
    # Then re-point the MAIN ractor's Rails.logger (the per-Ractor module
    # accessor, NOT in the app graph) at a fresh live BroadcastLogger writing
    # to $stderr — which is NOT reachable from the frozen app, so it stays
    # mutable. Workers already build their own per-Ractor Rails.logger in the
    # patched reader, so they're unaffected.
    def _neutralize_logger_io!(app)
      # A frozen, shareable no-op BroadcastLogger (no broadcasts → no IO) to
      # swap in for the app-instance logger graph.
      noop_logger = ::ActiveSupport::BroadcastLogger.new
      noop_logger.freeze
      Ractor.make_shareable(noop_logger)

      # Replace the app-instance logger + any IO reachable from the app graph.
      seen = {}
      stack = [app]
      until stack.empty?
        o = stack.pop
        next if o.equal?(nil) || seen[o.object_id]
        seen[o.object_id] = true
        begin
          o.instance_variables.each do |iv|
            begin; v = o.instance_variable_get(iv); rescue; next; end
            if iv == :@logger
              # Replace the app-instance / config logger with the no-op (so the
              # frozen app graph holds no live IO). Best-effort; rescue if the
              # owner is frozen.
              o.instance_variable_set(iv, noop_logger) rescue nil
            elsif v.is_a?(::IO) && (v == $stdout || v == $stderr || v == STDOUT || v == STDERR)
              # Any stray IO reference → a shareable no-op sink.
              sink = NoOpLogDev.new
              sink.freeze
              Ractor.make_shareable(sink)
              o.instance_variable_set(iv, sink) rescue nil
            elsif v
              stack << v
            end
          end
        rescue => e
          # BasicObject or frozen objects don't support instance_variables
        end
        if o.is_a?(Array); o.each { |e| stack << e if e }
        elsif o.is_a?(Hash); o.each { |_, val| stack << val if val }
        end
      end

      # Re-point the MAIN ractor's Rails.logger at a fresh live logger (not
      # reachable from the frozen app) so main keeps logging after the app is
      # made shareable. $stderr is each-Ractor-local and not in the app graph,
      # so it stays mutable. Use the same shape Rails uses (BroadcastLogger
      # broadcasting to a Logger writing $stderr).
      if Ractor.main? && defined?(::Rails)
        live = ::ActiveSupport::BroadcastLogger.new(::Logger.new($stderr))
        ::Rails.logger = live
      end
    end

    # --- shareable fallback for framework class config ---

    # Build the shareable fallback for every class_attribute / mattr_accessor
    # value the shim has rerouted. For each registered attribute we:
    #   1. Read the main-ractor value (from its IES slot, which `redefine`
    #      seeded at class_attribute-definition time).
    #   2. Make it shareable (deep-freeze + callable-replacement for any Procs
    #      it holds — same technique as make_app_shareable!, applied to the
    #      config sub-graph).
    #   3. Store under the IES key in a frozen Hash on RactorRailsShim, which
    #      is readable from every Ractor (it's a constant).
    # Workers' class_attribute readers fall back to this when their own IES
    # slot is nil. Must run in the main Ractor. Idempotent.
    def _build_shareable_fallback!
      return if @fallback_built
      @fallback_built = true

        fallback = {}
        CLASS_ATTRIBUTES.each do |(owner_name, attr_name, ies_key, default_val)|
          # Skip the Rails logger — it's intrinsically unshareable (IO + Mutex +
          # mutable formatter) and workers build their own per-Ractor logger
          # via the patched reader. Trying to make it shareable would freeze the
          # IO, breaking logging in main too.
          next if owner_name == "Rails" && attr_name == :logger
          val = ActiveSupport::IsolatedExecutionState[ies_key]
          # For class_attribute values whose IES slot was never written but
          # whose definition-time DEFAULT was mutated in place during boot
          # (e.g. AbstractController::Base's `config`, whose default
          # ActiveSupport::OrderedOptions is filled with the real nested config
          # by railties), the live value lives in the main-Ractor
          # CLASS_ATTR_VALUES store, NOT in IES. Read it there so workers get
          # the real value instead of the empty definition-time default.
          if val.nil? && Ractor.main?
            val = RactorRailsShim::CLASS_ATTR_VALUES[ies_key]
          end
        # For mattr_accessor: the value may have been written to @@sym after
        # define-time (e.g. by an initializer). Read it from there if the IES
        # slot is nil (the seed only set the default; the live value may differ).
        if val.nil? && owner_name && attr_name.is_a?(Symbol)
          begin
            owner_mod = owner_name.split("::").inject(Object) { |ns, n| ns.const_get(n) } rescue nil
            if owner_mod && owner_mod.class_variable_defined?("@@#{attr_name}")
              val = owner_mod.class_variable_get("@@#{attr_name}")
            end
          rescue => e
            # ignore — best-effort read
          end
        end
        # For raw class ivars (PathRegistry, etc.): read @<attr_name> in main.
        if val.nil? && owner_name && attr_name.is_a?(Symbol)
          begin
            owner_mod = owner_name.split("::").inject(Object) { |ns, n| ns.const_get(n) } rescue nil
            if owner_mod && owner_mod.instance_variable_defined?("@#{attr_name}")
              val = owner_mod.instance_variable_get("@#{attr_name}")
            end
          rescue => e
            # ignore — best-effort read
          end
        end
        # For the Rails module accessors (owner_name == "Rails"): the value
        # may live in the @ivar (set by Rails' own writer via super, or
        # lazy-init'd by Rails' own reader) rather than in IES. Read it via
        # the actual accessor in main, which materializes the lazy-init value.
        if val.nil? && owner_name == "Rails" && defined?(::Rails)
          begin
            val = ::Rails.public_send(attr_name) if ::Rails.respond_to?(attr_name, false)
          rescue => e
            # ignore — best-effort read
          end
        end

        shareable_val = nil
        # Try the live value first.
        if !val.nil?
          shareable_val = _try_make_shareable(val, owner_name, attr_name)
        end
        # If the live value couldn't be shared (e.g. __callbacks holds
        # self-capturing Procs), fall back to the definition-time default.
        # For a frozen shared app this is correct: boot-time callbacks already
        # ran in main; workers treat them as already-run (empty/no-op). The
        # default is dup'd if it's a mutable container (Hash/Array) so each
        # entry in the fallback is an independent shareable copy.
        if shareable_val.nil? && !default_val.nil?
          shareable_val = _try_make_shareable(_shareable_copy(default_val), owner_name, attr_name, default: true)
        end

        fallback[ies_key] = shareable_val if shareable_val
      end
      fallback.freeze
      Ractor.make_shareable(fallback)

      # Make the shareable mattr-defaults subset shareable too (workers read
      # it via the constant). Frozen + reassigned via const_set.
      SHAREABLE_MATTR_DEFAULTS.freeze
      Ractor.make_shareable(SHAREABLE_MATTR_DEFAULTS)

      # Reassign the constants with the built (shareable) tables. const_set
      # warns "already initialized constant" — silence that one warning.
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        const_set(:SHAREABLE_FALLBACK, fallback)
        const_set(:SHAREABLE_MATTR_DEFAULTS, SHAREABLE_MATTR_DEFAULTS)
      ensure
        $VERBOSE = verbose
      end
      fallback
    end

    # Best-effort attempt to make `val` shareable (callable-replacement for
    # Procs + lock-replacement + make_shareable). Returns the shareable val,
    # or nil if it can't be made shareable. On failure, emits a warning
    # (unless `default:` — defaults are expected to sometimes be unshareable,
    # so we skip the noise).
    def _try_make_shareable(val, owner_name, attr_name, default: false)
      # __callbacks and validators hold callback chains / validator instances
      # with self-capturing Procs that can NEVER be made shareable. This is
      # expected: workers correctly treat callbacks as already-run (the
      # nil-safe run_callbacks patch yields the block directly). Skip the
      # attempt entirely — don't waste cycles traversing the graph, and don't
      # emit warnings for known-expected failures.
      attr_sym = attr_name.to_s
      return nil if attr_sym.end_with?("__callbacks") ||
                    attr_sym.end_with?("__validators") ||
                    attr_sym.end_with?("default_connection_handler")

      begin
        _replace_unshareable_procs!(val)
        _replace_locks_and_concurrent_maps!(val)
        Ractor.make_shareable(val)
        val
      rescue => e
        unless default
          warn "ractor-rails-shim: could not make attribute " \
               "#{owner_name}##{attr_name} shareable (#{e.class}: #{e.message[0,80]}); workers will fall back to default or nil"
        end
        nil
      end
    end

    # Return a fresh copy of a mutable default container (Hash/Array) so the
    # fallback entry is independent. Frozen/shareable defaults pass through.
    def _shareable_copy(val)
      case val
      when Hash then val.dup
      when Array then val.dup
      else val
      end
    end

    # --- callable / lock replacement classes ---
    # Defined via string eval on the singleton class so they're referenced
    # the same way the original code did (specs access via
    # RactorRailsShim.singleton_class.const_get).
    module_eval <<-RUBY, __FILE__, __LINE__ + 1
      class NoOpProc
        def call(*_); nil; end
        # A NoOpProc is a shareable stand-in for an arbitrary Proc in the app
        # graph. Some Rails code passes such values through `&block`, which
        # calls `#to_proc` and then requires the result to be a real Proc.
        # Return a frozen no-op lambda so the implicit conversion succeeds and
        # the (side-effect-free) call is a true no-op, matching `#call`.
        def to_proc
          @_to_proc ||= ->(*) { nil }.freeze
        end
      end
      class Callable
        def initialize(target, method_name)
          @target = target
          @method_name = method_name
        end
        def call(*args)
          @target.__send__(@method_name, *args)
        end
      end
      class CallableConst
        def initialize(value); @value = value; end
        def call(*_); @value; end
      end
      # Shareable snapshot of a Devise::Mapping. The real Mapping holds an
      # unshareable lambda (failure_app) plus a default-proc Hash (controllers),
      # so it can't be Ractor.make_shareable'd. Request-time code only reads a
      # handful of attributes (name, to/class, router_name, controllers, ...),
      # which are all shareable values. We copy those now (in main) into a
      # frozen Plain Old Object that plays the role of the Mapping in workers.
      class DeviseMappingSnapshot
        def initialize(mapping)
          @name         = mapping.name
          @klass        = mapping.to
          @router_name  = mapping.instance_variable_get(:@router_name)
          @singular     = mapping.instance_variable_get(:@singular)
          @scoped_path  = mapping.instance_variable_get(:@scoped_path)
          @path         = mapping.instance_variable_get(:@path)
          @path_prefix  = mapping.instance_variable_get(:@path_prefix)
          @format       = mapping.instance_variable_get(:@format)
          @sign_out_via = mapping.instance_variable_get(:@sign_out_via)
          @modules      = mapping.modules
          @strategies   = mapping.strategies
          @routes       = mapping.routes
          @used_helpers = mapping.used_helpers
          # controllers is a Hash with a default proc (unshareable) — copy the
          # entries into a plain frozen Hash.
          h = {}
          mapping.controllers.each { |k, v| h[k] = v } rescue nil
          @controllers = h.freeze
          # failure_app is either Devise::FailureApp (a shareable class) or a
          # lambda (when configured as a String) — keep only the shareable class.
          fa = mapping.instance_variable_get(:@failure_app)
          fa = ::Devise::FailureApp unless fa.is_a?(Class)
          @failure_app = fa
          freeze
        end

        def name; @name; end
        def to; @klass; end
        def router_name; @router_name; end
        def singular; @singular; end
        def scoped_path; @scoped_path; end
        def path; @path; end
        def path_prefix; @path_prefix; end
        def format; @format; end
        def sign_out_via; @sign_out_via; end
        def modules; @modules; end
        def strategies; @strategies; end
        def routes; @routes; end
        def used_helpers; @used_helpers; end
        def controllers; @controllers; end
        def failure_app; @failure_app; end
        def authenticatable?; @modules.any? { |m| m.to_s =~ /authenticatable/ }; end
        def no_input_strategies; @strategies & Devise::NO_INPUT; end
        def fullpath; "/#{@path_prefix}/#{@path}".squeeze("/"); end
        # Devise::Mapping defines one `x?` predicate per Devise module
        # (confirmable?, rememberable?, registerable?, ...) via `add_module`.
        # Rather than enumerate them, fall back for any `x?` predicate to
        # checking @modules — matching the generated behaviour.
        def respond_to_missing?(method, _)
          method.to_s.end_with?("?") || super
        end

        def method_missing(method, *args)
          s = method.to_s
          if s.end_with?("?") && args.empty?
            @modules.include?(s.chomp("?").to_sym)
          else
            super
          end
        end
      end

      def _devise_mapping_snapshot(mapping)
        DeviseMappingSnapshot.new(mapping)
      rescue
        nil
      end
      # StrategyServe / StrategyCall moved to action_dispatch.rb (ActionDispatch
      # routing mapper strategy procs).
      class NoOpLock
        def synchronize; yield; end
        def mon_synchronize; yield; end
        def lock; self; end
        def unlock; self; end
        def locked?; false; end
        def mon_enter; end
        def mon_exit; end
        def mon_locked?; false; end
        def try_lock; true; end
        def new_cond; Struct.new(:wait, :signal, :broadcast).new(-> {}, -> {}, -> {}); end
      end
      # NOTE: StrategyServe / StrategyCall (ActionDispatch::Routing::Mapper
      # strategy procs) and RequestCallable (CookieStore) are now defined in
      # action_dispatch.rb. DeviseMappingCallable + _devise_mapping_replacement
      # are in warden.rb; FILES_LOC + _find_files_server are in rack.rb. The
      # source-location constants (SSL_LOC / COOKIE_LOC / MAPPER_LOC /
      # DEVISE_SCOPE_LOC / FILES_LOC) live alongside their callables.
      # No-op log device sink: a frozen, shareable stand-in for an IO, swapped
      # in for $stdout/$stderr in the app's logger before make_shareable so
      # the real IOs aren't frozen. Responds to the write methods a
      # Logger::LogDevice might call.
      class NoOpLogDev
        def write(*_); self; end
        def <<(*_); self; end
        def puts(*_); self; end
        def print(*_); self; end
        def flush; self; end
        def close; self; end
        def sync=(*_); self; end
        def binmode; self; end
        def tty?; false; end
        def closed?; false; end
      end
    RUBY

    # --- graph traversal helpers ---

    def _precompute_lazy_ivars(app)
      app.env_config
      app.app_env_config rescue nil
      app.routes.url_helpers rescue nil
      app.routes.named_routes rescue nil
      app.routes.helpers rescue nil
    end

    # Force AR attribute-method generation for every loaded model in the MAIN
    # Ractor. See the call site in make_app_shareable! for why; without this a
    # worker Ractor dies with Ractor::IsolationError on the first model
    # instantiation (GeneratedAttributeMethods::LOCK is a non-shareable Monitor).
    def _generate_ar_attribute_methods!
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
    # call; they hold an Array of `[Regexp, Symbol]` pairs (shareable elements)
    # but the Array itself is mutable and therefore NOT Ractor-shareable. A
    # worker Ractor reading the ivar raises
    # `Ractor::IsolationError: can not get unshareable values from instance
    # variables of classes/modules`. `redirect_to @post` calls
    # `Post#respond_to?(:to_model)` in the worker, which reads this cache, so
    # the write-path 302 redirect dies. Building it in MAIN (where it is
    # reachable) and freezing the Array makes it shareable; the cache is never
    # mutated after build (`attribute_method_patterns_matching` only does
    # `.select` on it), so freezing is safe.
    def _warm_attribute_method_patterns!
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

    # Replace every Proc in the app graph with a callable/no-op object.
    # Multiple passes because the same Proc object can live in many
    # containers (e.g. deprecation behaviors shared across deprecators).
    # Doesn't dedup procs — must replace every occurrence.
    def _replace_unshareable_procs!(app)
      mw = (app.instance_variable_get(:@app) rescue nil)
      3.times do
        procs = _collect_procs(app)
        break if procs.empty?
        procs.each { |proc_obj, _path, parent, ivar| _replace_one_proc(proc_obj, parent, ivar, mw) }
      end
    end

    # BasicObject (and its subclasses) don't define respond_to?, so calling
    # o.respond_to? on one raises NoMethodError. Use this to safely test
    # whether an object can be introspected (is_a?, instance_variables, ...).
    def _introspectable?(o)
      o.respond_to?(:is_a?)
    rescue NoMethodError
      false
    end

    def _collect_procs(app)
      seen = {}
      procs = []
      stack = [[app, "app", nil, nil]]
      until stack.empty?
        o, _path, parent, ivar = stack.pop
        next if o.equal?(nil)
        # Skip BasicObject subclasses that don't respond to is_a?/object_id
        # (e.g. ActiveSupport::Callbacks::CallTemplate internals). Must guard
        # BEFORE calling is_a? — BasicObject doesn't define it.
        next unless _introspectable?(o)
        if o.is_a?(Proc)
          procs << [o, _path, parent, ivar]
          next
        end
        next if seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
        begin
          o.instance_variables.each do |iv|
            begin; v = o.instance_variable_get(iv); rescue; next; end
            stack << [v, "#{_path}.#{iv}", o, iv] if v
          end
        rescue => e
          # Some objects (BasicObject) don't support instance_variables
        end
        if o.is_a?(Array)
          o.each_with_index { |e, i| stack << [e, "#{_path}[#{i}]", o, nil] if e }
        elsif o.is_a?(Hash)
          o.each do |k, val|
            stack << [k, "#{_path}.key", o, nil] if k
            stack << [val, "#{_path}[#{k.inspect}]", o, nil] if val
          end
          dp = o.default_proc
          procs << [dp, "#{_path}.default_proc", o, :__default_proc__] if dp
        end
      end
      procs
    end

    def _replace_one_proc(proc_obj, parent, ivar, mw)
      src = proc_obj.source_location&.first || ""
      replacement =
        if src.end_with?(SSL_LOC) && ivar == :@exclude
          redirect = parent.instance_variable_get(:@redirect)
          CallableConst.new(!redirect)
        elsif src.end_with?(FILES_LOC) && ivar == :@app
          # The lambda is `Rack::Files#initialize`'s `lambda { |env| get env }`,
          # stored as `Rack::Head#@app`. Its `self` (binding receiver) is the
          # `Rack::Files` instance that defines `get` — NOT the `Rack::Head`
          # that holds it. Use the binding receiver as the callable target so
          # the worker calls `Rack::Files#get(env)` (the original behavior).
          # Fall back to the middleware-chain search if the receiver can't be
          # resolved (e.g. frozen/unavailable binding).
          receiver = proc_obj.binding.receiver rescue nil
          files_server = receiver if receiver && receiver.respond_to?(:get)
          files_server ||= _find_files_server(mw)
          files_server ||= parent
          Callable.new(files_server, :get)
        elsif src.end_with?(COOKIE_LOC)
          RequestCallable.new(:cookies_same_site_protection)
        elsif src.end_with?(DEVISE_SCOPE_LOC)
          _devise_mapping_replacement(proc_obj, parent)
        elsif src.end_with?(MAPPER_LOC) && ivar == :@strategy
          line = proc_obj.source_location[1]
          line == 32 ? StrategyServe.new : StrategyCall.new
        else
          NoOpProc.new
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
        parent.instance_variable_set(ivar, replacement) rescue nil
      elsif parent.is_a?(Array)
        idx = parent.index(proc_obj)
        if idx then parent[idx] = replacement
        else parent.each_with_index { |e, i| parent[i] = replacement if e.equal?(proc_obj) }
        end
      elsif parent.is_a?(Hash)
        key = parent.key(proc_obj)
        parent[key] = replacement if key rescue nil
      end
    end

    # NOTE: `_devise_mapping_replacement` (Devise scope constraint →
    # DeviseMappingCallable) now lives in warden.rb; `_find_files_server`
    # (Rack::Files target for the asset stack) now lives in rack.rb.

    def _replace_locks_and_concurrent_maps!(app)
      seen = {}
      stack = [[app, "app", nil, nil]]
      until stack.empty?
        o, _p, _parent, _ivar = stack.pop
        next if o.equal?(nil)
        next unless _introspectable?(o)
        next if seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
        begin
          o.instance_variables.each do |iv|
            begin; v = o.instance_variable_get(iv); rescue; next; end
            if v.is_a?(Mutex) || v.is_a?(Monitor)
              o.instance_variable_set(iv, NoOpLock.new) rescue nil
            elsif defined?(::Concurrent::Map) && v.is_a?(::Concurrent::Map)
              hash_copy = {}
              v.each_pair { |k, val| hash_copy[k] = val }
              o.instance_variable_set(iv, hash_copy) rescue nil
            elsif v
              stack << [v, "#{_p}.#{iv}", o, iv]
            end
          end
        rescue => e
          # BasicObject or frozen objects don't support instance_variables
        end
        if o.is_a?(Array); o.each_with_index { |e, i| stack << [e, "#{_p}[#{i}]", o, nil] if e }
        elsif o.is_a?(Hash); o.each { |k, val| stack << [k, "#{_p}.key", o, nil] if k; stack << [val, "#{_p}[#{k.inspect}]", o, nil] if val }
        end
      end
    end

    # Capture each controller's OWN declared `process_action` symbol filters
    # (before_action / after_action) so worker Ractors can replay them.
    #
    # WHY NOT READ __callbacks: Rails 8.1.3 under Ruby 4.0.5 (with Devise
    # 5.0.4) has an eager-load class_attribute callback-chain leak — a parent
    # controller's `__callbacks` accumulates every subclass's filters (and
    # vice-versa), so `ApplicationController.__callbacks[:process_action]`
    # ends up carrying Devise's `require_no_authentication` AND
    # `PostsController`'s `set_post`. Reading `__callbacks` therefore yields a
    # corrupted, unshareable chain. The app is genuinely broken in eager-load
    # (production) mode even without the shim.
    #
    # Instead we intercept `ActiveSupport::Callbacks.set_callback` during
    # eager load (see _install_callback_declaration_capture!) and record, per
    # declaring controller class, the symbolic filters IT declares (kind,
    # filter, only/except). This captures the truth regardless of the leak.
    # The patched run_callbacks replays these per controller, walking
    # ancestors for inheritance.
    #
    # We only capture SYMBOL filters (the common `before_action :set_post`
    # form). Proc/lambda filters are skipped — they are self-capturing and
    # cannot be replayed safely in a worker (known limitation; symbolic
    # filters cover the typical case, including Devise's `:authenticate_user!`
    # / `:require_no_authentication`). Stored in
    # RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS keyed by the controller
    # class object_id (stable across Ractors since classes are shared).
    # Make Ractor-shareable the class instance variables listed in
    # SHAREABLE_CLASS_IVARS (e.g. ActiveSupport::Editor.@editors,
    # Warden::Strategies.@strategies). Worker Ractors read these during request
    # dispatch; an unshareable value raises Ractor::IsolationError. We deep-freeze
    # the value and write it back so workers read the shareable copy. Also
    # pre-touch any memoizing accessor so workers don't try to write the ivar
    # lazily (which would raise FrozenError on the frozen class).
    def _freeze_shareable_class_ivars!
      SHAREABLE_CLASS_IVARS.each do |(class_name, ivar)|
        mod = class_name.split("::").inject(Object) { |ns, n| ns.const_get(n) } rescue nil
        next unless mod && mod.instance_variable_defined?(ivar)
        val = mod.instance_variable_get(ivar)
        next if val.nil?
        begin
          Ractor.make_shareable(val)
          mod.instance_variable_set(ivar, val) rescue nil
        rescue
          nil
        end
      end
      # Pre-touch memoizing accessors so workers short-circuit instead of
      # writing the (now frozen) ivar on first read.
      begin
        ::ActiveSupport::Editor.current if defined?(::ActiveSupport::Editor)
      rescue
        nil
      end
      begin
        ::Warden::Strategies._strategies if defined?(::Warden::Strategies)
      rescue
        nil
      end
    end

    def _freeze_declared_callbacks!
      table = (@declared_callbacks || {})
      # Deep-freeze (make shareable) so worker Ractors can read the constant.
      # Entries are Hashes of Symbols/booleans/nil/Arrays — all natively
      # shareable. A non-frozen constant raises Ractor::IsolationError when a
      # worker reads it.
      begin
        Ractor.make_shareable(table)
        RactorRailsShim.const_set(:SHAREABLE_DECLARED_CALLBACKS, table)
      rescue
        nil
      end
    end

    # Record a single declared symbolic filter. Called from the
    # set_callback interceptor during eager load (main Ractor only).
    def _record_declared_callback(klass_id, kind, filter, only, except)
      @declared_callbacks ||= {}
      (@declared_callbacks[klass_id] ||= []) << {
        kind: kind,
        filter: filter,
        only: (only.freeze if only),
        except: (except.freeze if except)
      }
    end

    # Install an interceptor on ActiveSupport::Callbacks.set_callback that
    # records, per declaring class, every symbolic `:process_action` filter
    # it declares. This must run BEFORE eager load (so declarations are
    # captured as they happen) — install wires it via
    # ActiveSupport.on_load(:active_support).
    def _install_callback_declaration_capture!
      return if @callback_capture_installed
      @callback_capture_installed = true
      # ActiveSupport::Callbacks may not be loaded yet at on_load(:active_support)
      # time (it's required lazily). Require it so the ClassMethods module with
      # set_callback exists before we alias it.
      require "active_support/callbacks" rescue nil
      mod = (defined?(::ActiveSupport::Callbacks) &&
             ::ActiveSupport::Callbacks.const_defined?(:ClassMethods)) ?
            ::ActiveSupport::Callbacks::ClassMethods : nil
      return unless mod && mod.method_defined?(:set_callback)
      mod.alias_method(:_rrs_orig_set_callback, :set_callback)
      mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def set_callback(name, *filters, &block)
          if name == :process_action && filters.length >= 2 && filters[0].is_a?(Symbol)
            kind = filters[0]
            filter = filters[1]
            if filter.is_a?(Symbol) &&
               self.is_a?(::Class) &&
               self.ancestors.include?(::AbstractController::Base)
              # Rails converts `only:`/`except:` into an ActionFilter object
              # stored in the callback's `:if`/`:unless` options (NOT a bare
              # `:only` key). Read the constraint back from the ActionFilter's
              # @conditional_key (:only/:except) and @actions (a Set of action
              # name Strings).
              opts = filters.find { |f| f.is_a?(Hash) }
              only = nil
              except = nil
              if opts
                [opts[:if], opts[:unless]].each do |arr|
                  next unless arr.is_a?(Array)
                  arr.each do |af|
                    ck = af.instance_variable_get(:@conditional_key) rescue nil
                    acts = af.instance_variable_get(:@actions) rescue nil
                    next unless ck && acts
                    acts = acts.to_a.map(&:to_sym) if acts.respond_to?(:to_a)
                    only = acts if ck == :only
                    except = acts if ck == :except
                  end
                end
              end
              ::RactorRailsShim._record_declared_callback(
                self.object_id, kind, filter, only, except)
            end
          end
          _rrs_orig_set_callback(name, *filters, &block)
        end
      RUBY
      @callback_capture_installed = true
    end

    def _collect_controller_classes(app)
      classes = []
      begin
        router = (app.respond_to?(:routes) ? app.routes : nil) || (defined?(::Rails) && ::Rails.application && ::Rails.application.routes)
        router.routes.each do |r|
          c = r.defaults[:controller] rescue nil
          next unless c && c.respond_to?(:camelize)
          klass = "#{c.camelize}Controller".safe_constantize rescue nil
          classes << klass if klass
        end
      rescue
        nil
      end
      begin
        if defined?(::ApplicationController) && ::ApplicationController.respond_to?(:descendants)
          classes.concat(::ApplicationController.descendants)
        end
      rescue
        nil
      end
      classes.compact.uniq
    end
  end
end
