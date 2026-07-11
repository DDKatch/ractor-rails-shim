# frozen_string_literal: true

# make_app_shareable! infrastructure: callable/lock replacement classes,
# graph traversal (collect procs, replace locks/maps), shareable fallback
# builder, and the main make_app_shareable! entry point.

module RactorRailsShim
  class << self
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
      _install_rack_request_patch
      _install_inflector_patch
      _install_parameter_encoding_patch
      _install_path_registry_patch
      _install_abstract_controller_patch
      _install_active_support_error_reporter_patch
      _install_lookup_context_patch
      _install_i18n_patch
      _install_template_handlers_patch
      _install_execution_context_patch
      _install_request_parameter_parsers_patch
      _install_rack_utils_patch
      _install_log_subscriber_patch
      _install_exception_wrapper_patch
      _install_warden_hooks_patch
      _install_action_dispatch_mounted_helpers_patch
      _install_activerecord_connection_handler_patch
      _install_activerecord_configurations_patch
      _install_activerecord_db_config_handlers_patch
      _install_activerecord_relation_delegate_cache_patch
      _install_activerecord_model_classes_patch
      _install_kaminari_config_patch
      _install_propshaft_patch
      _install_devise_url_helpers_patch
      # Pre-compute lazy ivars BEFORE freezing (they mutate the app).
      _precompute_lazy_ivars(app)
      _precompute_propshaft!(app)
      # Capture controller `process_action` symbol filters (before_action /
      # after_action) into a shareable table so worker Ractors can run them.
      # The shim routes class_attribute-backed `__callbacks` through IES and
      # seeds workers with the empty default, so controller filters do NOT run
      # in workers by default (see execution_wrapper.rb run_callbacks patch).
      # For GET requests that depend on a before_action (e.g. `set_post` loading
      # `@post`), that breaks rendering. We capture the symbolic filters here
      # (in main, before freeze) and the patched run_callbacks replays them.
      _capture_controller_callbacks!(app)
      # Warm + cache the routes' @ast / @simulator on the live graph. This MUST
      # run AFTER the route precompute above (which reloads/resets the routes)
      # and BEFORE _replace_unshareable_procs! / Ractor.make_shareable below:
      # the proc-replacement pass rewrites the Route constraint Procs held in
      # the simulator's @memos, and the freeze then shares the whole thing so
      # worker Ractors read the cached, frozen simulator via the original
      # Routes#simulator (no per-worker rebuild). See action_dispatch.rb.
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
      class RequestCallable
        def initialize(method_name); @method_name = method_name; end
        def call(request, response = nil); request.__send__(@method_name); end
      end
      class DeviseMappingCallable
        def initialize(mapping); @mapping = mapping; end
        def call(request)
          request.env["devise.mapping"] = @mapping
          true
        end
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
      class StrategyServe
        def call(app, req); app.serve(req); end
      end
      class StrategyCall
        def call(app, req); app.call(req.env); end
      end
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

    SSL_LOC = "/active_dispatch/middleware/ssl.rb".freeze
    FILES_LOC = "/rack/files.rb".freeze
    COOKIE_LOC = "/session/cookie_store.rb".freeze
    DEVISE_SCOPE_LOC = "/devise/rails/routes.rb".freeze
    MAPPER_LOC = "/action_dispatch/routing/mapper.rb".freeze

    # --- graph traversal helpers ---

    def _precompute_lazy_ivars(app)
      app.env_config
      app.app_env_config rescue nil
      app.routes.url_helpers rescue nil
      app.routes.named_routes rescue nil
      app.routes.helpers rescue nil
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
        next unless o.respond_to?(:is_a?)
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

    # Build a shareable replacement for a Devise scope constraint.
    # The original Proc (devise/rails/routes.rb:363) does:
    #   request.env["devise.mapping"] = Devise.mappings[scope]
    #   true
    # The scope is captured in the Proc's binding. We call the original
    # Proc once in main with a mock request to capture the mapping, then
    # make it shareable and wrap it in a DeviseMappingCallable.
    def _devise_mapping_replacement(proc_obj, parent)
      mock_env = { "devise.mapping" => nil }
      mock_req = Struct.new(:env).new(mock_env)
      begin
        proc_obj.call(mock_req)
      rescue
      end
      mapping = mock_env["devise.mapping"]
      if mapping
        mapping = _devise_mapping_snapshot(mapping)
      end
      if mapping
        DeviseMappingCallable.new(mapping)
      else
        CallableConst.new(true)
      end
    end

    def _find_files_server(mw)
      cur = mw
      while cur
        if cur.class.name == "ActionDispatch::Static"
          return cur.instance_variable_get(:@file_server)
        end
        cur = cur.instance_variable_get(:@app) rescue nil
      end
      nil
    end

    def _replace_locks_and_concurrent_maps!(app)
      seen = {}
      stack = [[app, "app", nil, nil]]
      until stack.empty?
        o, _p, _parent, _ivar = stack.pop
        next if o.equal?(nil)
        next unless o.respond_to?(:is_a?)
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

    # Capture controller `process_action` symbol filters (before_action /
    # after_action) so worker Ractors can run them. The shim routes
    # class_attribute-backed `__callbacks` through IES and seeds workers with
    # the empty default, so controller filters do NOT run in workers — which
    # breaks GET actions that depend on a before_action (e.g. `set_post`
    # loading `@post`). We only capture SYMBOL filters (the common
    # `before_action :set_post` form). Proc/lambda filters are skipped —
    # they are self-capturing and cannot be replayed safely in a worker
    # (known limitation; symbolic filters cover the typical case, including
    # Devise's symbol filters like `:authenticate_user!`). Each entry
    # records `before`/`after` and the `name` (the `only`/`except`
    # action constraint) so the patched run_callbacks can apply the right
    # subset per action. Stored in RactorRailsShim::SHAREABLE_CALLBACKS
    # keyed by the controller class object_id (stable across Ractors
    # since classes are shared).
    def _capture_controller_callbacks!(app)
      return unless Ractor.main?
      return if @controller_callbacks_captured
      @controller_callbacks_captured = true
      table = {}
      _collect_controller_classes(app).each do |klass|
        next unless klass.respond_to?(:__callbacks)
        cbs = klass.__callbacks rescue nil
        next unless cbs
        chain = cbs[:process_action] rescue nil
        next unless chain
        entries = []
        chain.each do |cb|
          f = cb.respond_to?(:filter) ? cb.filter : nil
          next unless f.is_a?(Symbol)
          # before/after is stored in `@kind` (`:before`/`:after`/`:around`),
          # NOT `@before`/`@after`. `@name` is the callback KIND
          # (`:process_action`), not the action constraint.
          kind = (cb.instance_variable_get(:@kind) rescue nil)
          before = (kind == :before)
          after  = (kind == :after)
          # The `only:`/`except:` action constraint lives in the
          # `ActionFilter` objects held by `@if`/`@unless` (NOT `@name`).
          # In Rails 8.1, ActionFilter stores the constraint as the
          # `@conditional_key` ivar (`:only`/`:except`) and `@actions` ivar
          # (a Set of action names as STRINGS). Both are ivars, not methods,
          # so read them via instance_variable_get and normalize the action
          # names to Symbols for the comparison in the replayed run_callbacks.
          only = nil
          except = nil
          [cb.instance_variable_get(:@if), cb.instance_variable_get(:@unless)].each do |arr|
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
          entries << {
            filter: f,
            before: before,
            after: after,
            only: (only.freeze rescue nil),
            except: (except.freeze rescue nil)
          }
        end
        table[klass.object_id] = entries.freeze unless entries.empty?
      end
      # Deep-freeze (make shareable) the whole table so worker Ractors can
      # read the constant. Entries are Hashes of Symbols/booleans/nil —
      # all natively shareable — so Ractor.make_shareable deep-freezes
      # cleanly. A non-frozen constant raises Ractor::IsolationError
      # ("can not access non-shareable objects in constant ... by non-main
      # Ractor") when a worker reads it.
      begin
        Ractor.make_shareable(table)
        RactorRailsShim.const_set(:SHAREABLE_CALLBACKS, table)
      rescue
        nil
      end
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
