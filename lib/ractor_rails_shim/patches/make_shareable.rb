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
    # app graph is frozen. Added here; make_constant_shareable! resolves each
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

    # Public API: make Rails.application shareable across Ractors. Delegates
    # to `RactorRailsShim::AppShareabilizer.make_shareable!(app)` (extracted
    # Step 22.6, Issue #22). See `AppShareabilizer` for the full pipeline
    # contract (precompute → freeze ivars → warm routes → neutralize logger
    # → replace procs → replace locks → make_shareable → build fallback).
    #
    # WARNING: this MUTATES the app object graph in place (replaces ivars).
    # The app becomes read-only (frozen). Do NOT call if you intend to keep
    # mutating the app (e.g. development reloading). Production-only.
    #
    # Returns the shareable app. Raises on failure (e.g. if a Proc can't be
    # replaced — add the missing constant to shareable_constants first).
    def make_app_shareable!(app = Rails.application)
      AppShareabilizer.make_shareable!(app)
    end

    # Detach the logger IO from the app graph so Ractor.make_shareable(app)
    # doesn't freeze the process's real $stdout/$stderr. Delegates to
    # `RactorRailsShim::LoggerIONeutralizer.call(app)` (extracted Step 22.3,
    # Issue #22). See `LoggerIONeutralizer` for the full contract (graph
    # walk, @logger -> no-op BroadcastLogger, stray IO -> NoOpLogDev,
    # main-Ractor Rails.logger re-point).
    def _neutralize_logger_io!(app)
      LoggerIONeutralizer.call(app)
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
    # Build the shareable fallback for every class_attribute / mattr_accessor
    # value the shim has rerouted. Delegates to FallbackBuilder.build!
    # (extracted Issue #13, Step 13.3). See FallbackBuilder for the contract.
    def _build_shareable_fallback!
      FallbackBuilder.build!
    end

    # Best-effort attempt to make `val` shareable. Delegates to
    # FallbackBuilder.try_make_shareable (extracted Issue #13, Step 13.3).
    def _try_make_shareable(val, owner_name, attr_name, default: false)
      FallbackBuilder.try_make_shareable(val, owner_name, attr_name, default: default)
    end

    # Return a fresh copy of a mutable default container (Hash/Array) so the
    # fallback entry is independent. Frozen/shareable defaults pass through.
    # Delegates to FallbackBuilder.shareable_copy (extracted Issue #13,
    # Step 13.3).
    def _shareable_copy(val)
      FallbackBuilder.shareable_copy(val)
    end

    # --- callable / lock replacement classes ---
    # NoOpProc / Callable / CallableConst / DeviseMappingSnapshot / NoOpLock /
    # NoOpLogDev + the _devise_mapping_snapshot helper now live in
    # patches/callables.rb (required before this file).
    # StrategyServe / StrategyCall (ActionDispatch routing) are in
    # action_dispatch.rb; RequestCallable (CookieStore) is in action_dispatch.rb;
    # DeviseMappingCallable + _devise_mapping_replacement are in warden.rb.

    # --- graph traversal helpers ---
    # The graph-traversal machinery (collect_procs, replace_unshareable_procs!,
    # replace_one_proc, replace_locks_and_concurrent_maps!, each_ivar_and_child,
    # enumerable_but_not_basic?, introspectable?, precompute_lazy_ivars,
    # generate_ar_attribute_methods!, warm_attribute_method_patterns!) is
    # extracted to RactorRailsShim::ShareabilityTraversal (Issue #13, Step
    # 13.2). The methods below are facade delegations preserving the existing
    # public/private API and the make_shareable_spec suite. Cross-concern
    # helpers (_find_files_server in rack.rb, _devise_mapping_replacement in
    # warden.rb) and the callable classes (NoOpProc, Callable, CallableConst,
    # RequestCallable, StrategyServe, StrategyCall) remain where they are and
    # are reached by the traversal through this facade.

    def _precompute_lazy_ivars(app)
      ShareabilityTraversal.precompute_lazy_ivars(app)
    end

    # Force AR attribute-method generation for every loaded model in the MAIN
    # Ractor. See the call site in make_app_shareable! for why; without this a
    # worker Ractor dies with Ractor::IsolationError on the first model
    # instantiation (GeneratedAttributeMethods::LOCK is a non-shareable Monitor).
    # Delegates to ShareabilityTraversal.generate_ar_attribute_methods!
    # (extracted Issue #13, Step 13.2).
    def _generate_ar_attribute_methods!
      ShareabilityTraversal.generate_ar_attribute_methods!
    end

    # Build + freeze ActiveModel's per-class `attribute_method_patterns_cache`
    # (and `attribute_method_matchers`) in the MAIN Ractor for every loaded
    # model. See ShareabilityTraversal.warm_attribute_method_patterns! for the
    # full rationale. Delegates (extracted Issue #13, Step 13.2).
    def _warm_attribute_method_patterns!
      ShareabilityTraversal.warm_attribute_method_patterns!
    end

    # Replace every Proc in the app graph with a callable/no-op object.
    # Multiple passes because the same Proc object can live in many
    # containers (e.g. deprecation behaviors shared across deprecators).
    # Doesn't dedup procs — must replace every occurrence. Delegates to
    # ShareabilityTraversal.replace_unshareable_procs! (extracted Issue #13,
    # Step 13.2).
    def _replace_unshareable_procs!(app)
      ShareabilityTraversal.replace_unshareable_procs!(app)
    end

    # BasicObject (and its subclasses) don't define respond_to?, so calling
    # o.respond_to? on one raises NoMethodError. Use this to safely test
    # whether an object can be introspected (is_a?, instance_variables, ...).
    # Delegates to ShareabilityTraversal.introspectable? (extracted Issue #13,
    # Step 13.2).
    def _introspectable?(o)
      ShareabilityTraversal.introspectable?(o)
    end

    # Gathers every Proc in the app graph. Delegates to
    # ShareabilityTraversal.collect_procs (extracted Issue #13, Step 13.2).
    def _collect_procs(app)
      ShareabilityTraversal.collect_procs(app)
    end

    # Enumerate every child reference of `o` for the graph traversals:
    #   - instance variables (yields [value, iv])
    #   - Array / Set / Enumerable members (yields [member, nil])
    #   - Hash pairs (yields [key, nil] and [val, nil])
    #   - Hash#default_proc (yields [proc, :__default_proc__])
    #   - Struct members (yields [value, nil] via #each_pair)
    #
    # Centralized so _collect_procs and _replace_locks_and_concurrent_maps!
    # share the same container coverage (Array, Hash, Set, Struct).
    # Delegates to ShareabilityTraversal.each_ivar_and_child (extracted
    # Issue #13, Step 13.2).
    def _each_ivar_and_child(o)
      ShareabilityTraversal.each_ivar_and_child(o) { |child, ivar| yield child, ivar }
    end

    # True if `o` is Enumerable but NOT one of the container types with a
    # dedicated branch in _each_ivar_and_child. Used to gate the generic
    # Enumerable fallback so we don't double-walk Array/Hash/etc. Delegates
    # to ShareabilityTraversal.enumerable_but_not_basic? (extracted Issue
    # #13, Step 13.2).
    def _enumerable_but_not_basic?(o)
      ShareabilityTraversal.enumerable_but_not_basic?(o)
    end

    # Per-Proc replacement dispatch. Delegates to
    # ShareabilityTraversal.replace_one_proc (extracted Issue #13, Step 13.2).
    def _replace_one_proc(proc_obj, parent, ivar, mw)
      ShareabilityTraversal.replace_one_proc(proc_obj, parent, ivar, mw)
    end

    # NOTE: `_devise_mapping_replacement` (Devise scope constraint →
    # DeviseMappingCallable) now lives in warden.rb; `_find_files_server`
    # (Rack::Files target for the asset stack) now lives in rack.rb.

    # Identify which ActionDispatch strategy a Proc is and return its
    # shareable replacement. Delegates to
    # `RactorRailsShim::ActionDispatchStrategy.replacement_for(proc_obj)`
    # (extracted Step 22.5, Issue #22). See `ActionDispatchStrategy` for
    # the contract (SERVE/CALL identity dispatch via `equal?`, NoOpProc
    # fallback for unknown Procs).
    def _strategy_replacement_for(proc_obj)
      ActionDispatchStrategy.replacement_for(proc_obj)
    end

    # Replace Mutex/Monitor → NoOpLock and Concurrent::Map → Hash throughout
    # the app graph. Delegates to ShareabilityTraversal.replace_locks_and_
    # concurrent_maps! (extracted Issue #13, Step 13.2).
    def _replace_locks_and_concurrent_maps!(app)
      ShareabilityTraversal.replace_locks_and_concurrent_maps!(app)
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
        mod = RactorRailsShim._safe_const_get(class_name)
        next unless mod && mod.instance_variable_defined?(ivar)
        val = mod.instance_variable_get(ivar)
        next if val.nil?
        _swallow("freeze global ivar #{class_name}#{ivar}") do
          Ractor.make_shareable(val)
          mod.instance_variable_set(ivar, val)
        end
      end
      # Pre-touch memoizing accessors so workers short-circuit instead of
      # writing the (now frozen) ivar on first read.
      _swallow("freeze global ivar ActiveSupport::Editor.current") do
        ::ActiveSupport::Editor.current if defined?(::ActiveSupport::Editor)
      end
      _swallow("freeze global ivar Warden::Strategies._strategies") do
        ::Warden::Strategies._strategies if defined?(::Warden::Strategies)
      end
    end

    # Freeze (make Ractor-shareable) the captured declared-callbacks table.
    # Delegates to CallbackCapture.freeze_declared_callbacks! (extracted
    # Issue #13, Step 13.5). See CallbackCapture for the contract.
    def _freeze_declared_callbacks!
      CallbackCapture.freeze_declared_callbacks!
    end

    # Record a single declared symbolic filter. Delegates to
    # CallbackCapture.record_declared_callback (extracted Issue #13, Step
    # 13.5). Called from the set_callback interceptor during eager load.
    def _record_declared_callback(klass_id, kind, filter, only, except)
      CallbackCapture.record_declared_callback(klass_id, kind, filter, only, except)
    end

    # Install an interceptor on ActiveSupport::Callbacks.set_callback.
    # Delegates to CallbackCapture.install_callback_declaration_capture!
    # (extracted Issue #13, Step 13.5). See CallbackCapture for the contract.
    def _install_callback_declaration_capture!
      CallbackCapture.install_callback_declaration_capture!
    end

    # Read @conditional_key and @actions off an ActionFilter instance.
    # Delegates to CallbackCapture.read_action_filter_constraints (extracted
    # Issue #13, Step 13.5). See CallbackCapture for the version-gated
    # contract.
    def _read_action_filter_constraints(af)
      CallbackCapture.read_action_filter_constraints(af)
    end

    # Read an ivar; if undefined and debug? is true, emit a labeled warning.
    # Delegates to CallbackCapture.read_ivar_or_warn (extracted Issue #13,
    # Step 13.5).
    def _read_ivar_or_warn(obj, ivar, label)
      CallbackCapture.read_ivar_or_warn(obj, ivar, label)
    end

    # Collect the set of loaded controller classes from the app's routes
    # table and ApplicationController.descendants. Delegates to
    # `RactorRailsShim::ControllerCollector.call(app)` (extracted Step
    # 22.4, Issue #22). See `ControllerCollector` for the contract (two
    # _swallow-funneled branches, compact.uniq dedup).
    def _collect_controller_classes(app)
      ControllerCollector.call(app)
    end
  end
end
