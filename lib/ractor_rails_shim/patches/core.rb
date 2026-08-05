# frozen_string_literal: true

require "active_support/lazy_load_hooks"

# Core: module-level constants, the install entry point, prepare_for_ractors!,
# version detection helpers, and the patch registry. All other patch files
# reopen `class << self` to add their `_install_*` methods.

module RactorRailsShim
  # The keys under which each global is stored in IsolatedExecutionState.
  # Namespaced to avoid collisions with Rails' own uses of IES.
  KEYS = {
    application: :ractor_rails_shim_application,
    app_class: :ractor_rails_shim_app_class,
    cache: :ractor_rails_shim_cache,
    logger: :ractor_rails_shim_logger,
    env: :ractor_rails_shim_env,
    backtrace_cleaner: :ractor_rails_shim_backtrace_cleaner
  }.freeze

  # Registry of every class_attribute definition the shim's `redefine` patch
  # has seen. Each entry is [owner_name, namespaced_name (Symbol), key (Symbol)]
  # so that at `prepare_for_ractors!` time we can capture the main-ractor value
  # of each attribute, make it shareable, and expose it as a read-only fallback
  # for worker Ractors (whose own IES slot is empty). Without this, framework
  # class config (ActionController::Base.config, etc.) is per-Ractor-nil in
  # workers and request dispatch dies (e.g. default_static_extension -> config
  # is nil). The fallback is ONLY read by workers; the main ractor keeps its
  # own live (possibly mutable) value in its IES slot, untouched.
  #
  # The fallback table itself is built once, at prepare_for_ractors! time, and
  # made shareable; workers read it via a constant (RactorRailsShim::SHAREABLE_FALLBACK).
  CLASS_ATTRIBUTES = []
  # Shareable registry: controller class → abstract? boolean. Populated at
  # prepare_for_ractors! time by scanning all AbstractController::Base
  # descendants for their @abstract ivar. Workers read this via the
  # patched AbstractController::Base.abstract? (per-class values can't live in
  # per-Ractor IES). Made shareable (frozen) at prepare time.
  ABSTRACT_REGISTRY = Ractor.make_shareable({})
  # Runtime registry: mattr_accessor IES key → default value. Written at
  # mattr-definition time (boot, in main); the mattr reader (string-eval'd)
  # looks the default up here by key (defaults can't be inlined into the
  # eval'd body — a Logger's `.inspect` is invalid Ruby). NOT made shareable
  # (some defaults like Logger are intrinsically unshareable); the reader
  # only consults this for defaults that are Ractor.shareable?.
  MATTR_DEFAULTS = {}
  # class_attribute default values, keyed by IES key. Written at
  # class_attribute-definition time (boot, in main). The class_attribute reader
  # falls back to this in the MAIN ractor when the IES slot is empty (which it
  # is on non-boot threads — IES is thread-local, and Puma's request threads
  # have empty slots). NOT made shareable (values may be mutable Hashes/Arrays);
  # only safe to read from the main ractor. Workers use SHAREABLE_FALLBACK
  # (built at prepare_for_ractors! time) instead.
  CLASS_ATTR_VALUES = {}
  # Shareable subset of MATTR_DEFAULTS: only defaults that are
  # Ractor.shareable? (so workers can read the constant safely). Written at
  # mattr-definition time (boot, in main, before workers spawn); frozen +
  # made shareable at prepare_for_ractors! time.
  SHAREABLE_MATTR_DEFAULTS = {}
  # Registry of constant path strings ("A::B::C") whose values are mutable
  # Arrays/Hashes/Sets that need to be made shareable (deep-frozen) at boot.
  # Each per-concern file concats its own constants into this array. Users
  # can add their own via RactorRailsShim.shareable_constants << "MyGem::LIST".
  SHAREABLE_CONSTANTS = []
  # Registry of [ClassName, :ivar] pairs: class-level instance variables whose
  # values are mutable (Hashes/Arrays/objects) and must be made Ractor-shareable
  # (deep-frozen) at boot so worker Ractors can read them. Unlike
  # SHAREABLE_CONSTANTS (top-level constants), these are class instance
  # variables (e.g. ActiveSupport::Editor.@editors, Warden::Strategies.@strategies)
  # that hold unshareable values and are read during request dispatch.
  SHAREABLE_CLASS_IVARS = []
  # Shareable registry: controller class → its built view_context_class.
  # Populated at prepare_for_ractors! time by calling view_context_class on
  # each loaded controller in main (build_view_context_class uses
  # Class.new{...} blocks → un-shareable Proc from a worker). Made shareable.
  VIEW_CONTEXT_REGISTRY = Ractor.make_shareable({})
  # Frozen, shareable fallback table for class_attribute / mattr_accessor
  # values. Built once at prepare_for_ractors! time from the main ractor's
  # live values (class_attribute IES slot / mattr @@sym), each made shareable
  # via callable-replacement + make_shareable. Workers read this via the
  # RactorRailsShim::SHAREABLE_FALLBACK constant when their own IES slot is
  # empty. Values that can't be made shareable are skipped (workers see nil
  # for those and must set their own).
  SHAREABLE_FALLBACK = Ractor.make_shareable({})

  # Registry of patch names → tested Rails version segments. Owned by
  # VersionPolicy; the constant here is an alias so the historical
  # RactorRailsShim::PATCH_VERSIONS reference keeps working.
  PATCH_VERSIONS = RactorRailsShim::VersionPolicy::PATCH_VERSIONS

  # Alias for backward compatibility — errors are catchable as either
  # RactorRailsShim::UnsupportedVersionError or
  # RactorRailsShim::VersionPolicy::UnsupportedVersionError.
  UnsupportedVersionError = RactorRailsShim::VersionPolicy::UnsupportedVersionError

  class << self
    # Accessor for the abstract-controller registry (written by abstract! in
    # main, read by abstract? in workers). Reassigned to a shareable frozen
    # Hash at prepare_for_ractors! time.
    attr_accessor :_abstract_registry
    attr_accessor :_view_context_registry
    attr_accessor :_view_context_fallback

    # Policy for version mismatches. One of :warn (default), :strict, :off.
    # Set before `install`:
    #   RactorRailsShim.version_policy = :strict
    # Delegates to RactorRailsShim::VersionPolicy.policy.
    def version_policy
      RactorRailsShim::VersionPolicy.policy
    end

    def version_policy=(value)
      RactorRailsShim::VersionPolicy.policy = value
    end

    # When true, swallowed exceptions in freeze/shareability paths are
    # reported to $stderr so a worker Ractor that later crashes on an
    # unshareable value has a traceable cause. Default false (silent, the
    # historical behaviour). Enable for diagnosis:
    #   RactorRailsShim.debug = true
    def debug?
      defined?(@debug) ? @debug : false
    end
    attr_writer :debug

    # Swallow an exception raised by the block, optionally logging it when
    # `debug?` is on. Used by freeze/shareability paths where individual
    # failures are expected (some ivars hold intrinsically unshareable
    # values like Procs) but a worker crash on the same value later has no
    # visible cause. `label` identifies the call site (e.g. "freeze AR ivar
    # Post@column_defaults"). Keep the label short — it's only for grepping.
    def _swallow(label)
      yield
    rescue StandardError => e
      warn "[ractor_rails_shim] #{label}: #{e.class}: #{e.message[0, 120]}" if debug?
      nil
    end

    # Reassign a constant on RactorRailsShim with a new shareable value,
    # silencing the "already initialized constant" warning that const_set
    # emits when the constant was previously defined. Centralizes the
    # $VERBOSE-suppressed const_set dance that was repeated at every
    # shareable-constant rebuild site (SHAREABLE_FALLBACK,
    # SHAREABLE_MATTR_DEFAULTS, etc.). The value MUST already be frozen +
    # shareable — this method does not make it so.
    def _reassign_shareable_const(name, value)
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        const_set(name, value)
      ensure
        $VERBOSE = verbose
      end
    end

    SUPPORTED_RUBY = RactorRailsShim::Version::SUPPORTED_RUBY
    SUPPORTED_RAILS = "8.1"

    # Install all the patches. Safe to call multiple times (idempotent).
    #
    # May be called either before or after Rails is loaded:
    #   - If Rails is already defined (e.g. `Bundler.require` ran first), the
    #     Rails module accessors are patched immediately.
    #   - If Rails is not yet defined (the normal `config/boot.rb` case, where
    #     `install` is called before `require "rails"`), a one-shot load hook
    #     defers the Rails-module patch until `rails.rb` is loaded. The
    #     `mattr_accessor` macro patch (a `Module.prepend`) applies
    #     immediately regardless, because it patches the macro itself, not
    #     any Rails constant.
    # True when the shim should install its THREAD-server (Puma/Falcon) mode
    # instead of the default Ractor (kino) mode. In thread mode Ractor.main? is
    # true, so Rails' own globals (class variables / class ivars) are
    # thread-safe and used as-is; only the class_attribute callback-chain
    # isolation fix and the nil-safe callback replay are installed. The other
    # patches route framework globals through per-Ractor
    # IsolatedExecutionState, which is empty on Puma's request threads and
    # would break the app, so they are skipped.
    #
    # Configuration is owned by RactorRailsShim::RunMode: set explicitly via
    # `RactorRailsShim.thread_mode = true` (or `RunMode.thread = true`), or
    # let `install` resolve it from `ENV["SERVER"]`
    # (puma|falcon|thin|webrick|thread*). The decision is a configuration
    # responsibility extracted from `install` per POODR; `install` calls
    # `RunMode.resolve!` (a no-op when already configured explicitly) and then
    # reads `RunMode.thread?`. These facade methods delegate for backward
    # compatibility with existing call sites (patches/class_attribute.rb,
    # patches/active_support.rb, specs).
    def thread_mode?
      RactorRailsShim::RunMode.thread?
    end

    def thread_mode=(value)
      RactorRailsShim::RunMode.thread = value
    end

    def install
      _check_version_support
      # Resolve the run mode (Ractor vs thread-server). Configuration is owned
      # by RunMode — explicit `thread_mode=` wins; otherwise we fall back to
      # ENV["SERVER"]. Lifted out of the old inline ENV read so install is no
      # longer non-deterministic on ambient ENV with no visible config surface.
      RactorRailsShim::RunMode.resolve!

      if thread_mode?
        # Minimal install for thread (Puma/Falcon) servers: only the
        # class_attribute isolation fix + nil-safe callback replay. The other
        # patches route framework globals through per-Ractor IES, which is
        # empty on Puma's request threads and would break the app, so they are
        # skipped; the original Rails globals are thread-safe and used as-is.
        install_class_attribute
        install_execution_wrapper
        # Capture each controller's OWN declared before_action/after_action
        # filters at declaration time (during eager load) by intercepting
        # ActiveSupport::Callbacks.set_callback. This must be installed BEFORE
        # eager load so declarations are captured as they happen — the
        # class_attribute callback chain is corrupted by an eager-load leak
        # under Ruby 4.0.5 + Rails 8.1.3 + Devise, so reading __callbacks later
        # yields a wrong, unshareable chain. Install requires active_support/
        # callbacks to be loaded, so require it first; install runs before the
        # app's eager_load, so every controller declaration is captured.
        require "active_support/callbacks" rescue nil
        _install_callback_declaration_capture!
      else
        install_mattr_accessor
        install_class_attribute
        install_zeitwerk_registry
        install_rubygems
        install_rails_module
        install_shareable_constants
        install_execution_wrapper
        require "active_support/callbacks" rescue nil
        _install_callback_declaration_capture!
        # Patch ActionView::Base.with_empty_template_cache EARLY (before eager
        # load) so production's DetailsKey.view_context_class uses the block-free
        # version. The framework's original defines compiled_method_container via
        # define_method(&block) — an un-shareable Proc that breaks worker
        # Ractors. on_load fires as soon as ActionView is required, well before
        # the app's eager_load.
        ActiveSupport.on_load(:action_view) do
          RactorRailsShim._install_with_empty_template_cache_patch
        end
      end
      @installed = true
      true
    end

    def installed?
      @installed ||= false
    end

    # --- Generic constant-sharing utilities (moved from rails_module.rb) -----
    # These are framework-agnostic; SHAREABLE_CONSTANTS lives here too, so the
    # whole constant-shareability machinery is owned by core.rb. The machinery
    # itself is extracted to RactorRailsShim::ConstantShareabilizer (Issue #13,
    # Step 13.1); the methods below are facade delegations preserving the
    # existing public/private API and the naming-convention / shim / safe_const
    # _get / make_value_shareable specs.

    def shareable_constants
      ConstantShareabilizer.shareable_constants
    end

    def install_shareable_constants
      ConstantShareabilizer.install
    end

    # Run after Rails is fully booted (after Rails.application.initialize!)
    # and BEFORE spawning worker Ractors. Re-attempts to make every
    # registered constant shareable; constants that didn't exist at install
    # time (e.g. Rails::Railtie, loaded after `module Rails` opens) get
    # fixed here. Safe to call multiple times; already-shareable constants
    # are no-ops. MUST run in the main Ractor (const_set writes the constant
    # table). Public wrapper is `prepare_for_ractors!` above. Delegates to
    # ConstantShareabilizer.apply! (extracted Issue #13, Step 13.1).
    def _apply_shareable_constants!
      ConstantShareabilizer.apply!
    end

    # Resolve a constant path string to a value, and if it exists and is
    # not already shareable, replace it with its shareable (deep-frozen)
    # version. Returns true if the constant was made shareable (or already
    # was); false if it doesn't exist yet (caller may retry). Delegates to
    # ConstantShareabilizer.make_shareable (extracted Issue #13, Step 13.1).
    def make_constant_shareable(const_path)
      ConstantShareabilizer.make_shareable(const_path)
    end

    # Best-effort shareable replacement for a constant value. Monitor/Mutex
    # become a NoOpLock (never contended post-boot). BasicObject instances
    # (used as sentinel sentinels, e.g. PRIMARY_KEY_NOT_SET) can't be frozen
    # (BasicObject has no #freeze method) — replace with a frozen Symbol.
    # Everything else is deep-frozen via Ractor.make_shareable; if that
    # fails (e.g. a Proc, or a Concurrent::Map / TypeMap holding Procs —
    # both intrinsically unshareable and needing upstream Rails changes),
    # returns nil and the constant is left as-is (the worker will raise a
    # clear IsolationError on read). Delegates to
    # ConstantShareabilizer.make_value_shareable (extracted Issue #13,
    # Step 13.1). Uses the existing _introspectable? helper (make_shareable.rb)
    # instead of ad-hoc `rescue false` guards.
    def _make_value_shareable(val)
      ConstantShareabilizer.make_value_shareable(val)
    end

    # Resolve a constant path string (e.g. "A::B::C") to its value, returning
    # nil if any segment isn't defined. When inherit is false, each segment
    # is looked up only in its parent's own constant table (const_get name,
    # false), matching the original no-inherit lookups in
    # _freeze_messages_constants!. Replaces dense rescue/& chains like:
    #   (Object.const_get(:A) rescue nil)&.const_get(:B, false) rescue nil
    # Delegates to ConstantShareabilizer.safe_const_get (extracted Issue
    # #13, Step 13.1).
    def _safe_const_get(path, inherit: true)
      ConstantShareabilizer.safe_const_get(path, inherit: inherit)
    end

    # Split "A::B::C" into [A::B (module), :C]. Returns [nil, nil] if the
    # parent isn't defined. Delegates to ConstantShareabilizer.split_const_path
    # (extracted Issue #13, Step 13.1).
    def split_const_path(path)
      ConstantShareabilizer.split_const_path(path)
    end

    # _install_*_patch methods called from OTHER install paths, not from the
    # dispatcher. They are installed by their parent install method (e.g.
    # _install_callbacks_nil_safe_patch and _install_notifications_notifier_patch
    # are called from patch_execution_wrapper!; _install_with_empty_template_cache_patch
    # is called from install via ActiveSupport.on_load). Excluded from
    # auto-discovery so they aren't double-installed.
    NON_DISPATCHED_FRAMEWORK_PATCHES = Ractor.make_shareable(%i[
      _install_callbacks_nil_safe_patch
      _install_notifications_notifier_patch
      _install_with_empty_template_cache_patch
    ].freeze)

    # Auto-discover and call every _install_*_patch singleton method. Both
    # `prepare_for_ractors!` (pre-worker boot) and `make_app_shareable!`
    # (post-boot, pre-freeze) call this. Each _install_* is idempotent (guarded
    # by its own @*_patched flag), so calling the full set at either point is a
    # no-op for already-applied patches. The method table IS the registry —
    # adding a new _install_*_patch method to any patch file automatically
    # includes it here without editing this dispatcher (Open/Closed).
    def _install_all_framework_patches
      (singleton_class.instance_methods(false) +
       singleton_class.private_instance_methods(false))
        .map(&:to_sym)
        .select { |m| m.to_s.start_with?("_install_") && m.to_s.end_with?("_patch") }
        .reject { |m| m == :_install_all_framework_patches || NON_DISPATCHED_FRAMEWORK_PATCHES.include?(m) }
        .each { |m| __send__(m) }
    end

    # Public API: run after Rails.application.initialize! and BEFORE spawning
    # worker Ractors. Makes every registered constant shareable (deep-freeze).
    # Constants that didn't exist at install time (e.g. Rails::Railtie, loaded
    # after `module Rails` opens) get fixed here. Idempotent; safe to call
    # multiple times. Must run in the main Ractor.
    #
    # NOTE: this does NOT build the framework-config shareable fallback. That
    # step is folded into `make_app_shareable!` because some class_attribute /
    # mattr_accessor values reference the app graph, and making them shareable
    # must happen AFTER the app itself is already frozen (otherwise the app
    # gets frozen prematurely and precompute/proc-replacement can't mutate
    # it). If you call prepare_for_ractors! standalone (without
    # make_app_shareable!), worker Ractors will see nil for framework config
    # values that couldn't be shared without freezing the app — set them
    # explicitly per worker, or use make_app_shareable!.
    def prepare_for_ractors!
      _apply_shareable_constants!
      RactorRailsShim._freeze_shareable_class_ivars! if RactorRailsShim.respond_to?(:_freeze_shareable_class_ivars!)
      snapshot_gem_paths!
      snapshot_query_logs!
      _install_all_framework_patches
      install_url_helpers_patch
      fix_url_helpers_singleton_routes!
      _warm_active_record_class_caches!
      _freeze_active_record_class_ivars!
      _freeze_global_class_ivars!
      _freeze_global_constants!
      _freeze_messages_constants!
    end

    # Verify the runtime matches the versions the shim was developed against.
    # The shim's patches target specific Rails 8.1 class layouts and Ruby 4.0
    # Ractor semantics. On other versions, the patches may silently miss or
    # break things. Behavior on mismatch is governed by `version_policy`:
    #
    #   :warn   (default) print a warning to $stderr, proceed anyway
    #   :strict raise RactorRailsShim::UnsupportedVersionError
    #   :off    silent (for advanced users / experimentation)
    #
    # Ruby mismatch always warns (Ractor semantics are not stable across
    # majors); Rails mismatch uses the policy. This is real version detection
    # (Gem::Version-based), not a string-prefix compare, so pre-release and
    # patch versions sort correctly.
    def _check_version_support
      unless RactorRailsShim::Version.supported_ruby?
        msg = "ractor-rails-shim: Ruby #{RUBY_VERSION} — shim requires " \
              "Ruby >= #{SUPPORTED_RUBY} (frozen-iseq call-cache fix #22075 " \
              "and cross-ractor env-string fix both shipped in 4.0.6). " \
              "Proceeding anyway."
        _version_mismatch(msg)
      end
      if RactorRailsShim::Version.rails &&
         !RactorRailsShim::Version.supported_rails?
        rv = ::Rails::VERSION::STRING
        msg = "ractor-rails-shim: Rails #{rv} — shim developed against " \
              "Rails #{RactorRailsShim::Version::TESTED_RAILS.join(", ")}. " \
              "Class layouts (class_attribute, callbacks, PathRegistry, etc.) " \
              "may differ; patches may miss blockers. Proceeding anyway. " \
              "Set RactorRailsShim.version_policy = :strict to make this " \
              "fatal; :off to silence."
        _version_mismatch(msg)
      end
    end

    # Apply the configured policy to a mismatch message.
    # Delegates to RactorRailsShim::VersionPolicy.mismatch.
    def _version_mismatch(message)
      RactorRailsShim::VersionPolicy.mismatch(message)
    end

    # Report which registered patches apply to the runtime Rails version
    # (and which were skipped because they're untested on it). Useful for
    # diagnostics and CI. Returns a Hash: { applied: [...], skipped: [...] }.
    # Delegates to RactorRailsShim::VersionPolicy.applicable.
    def applicable_patches
      RactorRailsShim::VersionPolicy.applicable
    end

    # Record that a patch was developed/tested against the given Rails version
    # segments. Delegates to RactorRailsShim::VersionPolicy.register.
    def _register_patch(name, *tested_segments)
      RactorRailsShim::VersionPolicy.register(name, *tested_segments)
    end

    # Capture a frozen name -> object map for every constant the application's
    # Zeitwerk loaders manage. Runs in the MAIN Ractor, after eager load, where
    # all app constants are defined. The map travels to worker Ractors, which
    # use it to (re)bind the constant *names* into their own namespaces.
    #
    # Why this is needed: a Ractor boundary does NOT share top-level constant
    # *names* — only the class/module *objects* reachable from the frozen shared
    # app graph cross the boundary. A worker Ractor therefore sees
    # `RactorRailsShim`, `ActiveRecord`, `ApplicationRecord`, the controllers,
    # etc. (objects reachable from the app), but NOT the application's own
    # model constants (e.g. `Post`): the object is in the graph, but its name
    # is not bound in the worker, so `PostsController#index`'s `Post` reference
    # raises NameError. Rebinding the captured names fixes it without
    # re-running autoloading (which is itself impossible in a worker, since
    # `Zeitwerk::Loader.new` raises IsolationError off the main Ractor).
    # Capture a frozen name -> object map for every constant the
    # application's Zeitwerk loaders manage. Delegates to
    # WorkerAppFactory.capture_constants (extracted Issue #13, Step 13.4;
    # WorkerApp moved to ractor_rails_shim/worker_app.rb). See
    # WorkerAppFactory for the contract (Zeitwerk introspection, the
    # non-Zeitwerk guard, and why the captured map is needed for worker
    # constant rebinding).
    def capture_app_constants
      WorkerAppFactory.capture_constants
    end

    # Build the shareable Rack app handed to kino. Delegates to
    # WorkerAppFactory.build (extracted Issue #13, Step 13.4). See
    # WorkerAppFactory for the shareability contract (returns a frozen,
    # Ractor.shareable? WorkerApp instance).
    def worker_app!(frozen_app)
      WorkerAppFactory.build(frozen_app)
    end

    # See patches/active_model_attribute.rb. When the frozen `:ractor` graph is
    # built, each model class's `_default_attributes` template (and the
    # FromDatabase instances within it) is deep-frozen. `Attribute#dup_or_share`
    # returns `self` for immutable column types, so a worker's NEW record would
    # share a frozen Attribute and raise FrozenError on first read/write. This
    # patch makes a frozen receiver yield a fresh, mutable Attribute so writes
    # (POST/create) work in workers. No-op in normal (unfrozen) Rails.
    def _install_active_model_attribute_patch
      return @am_attribute_patched if defined?(@am_attribute_patched) && @am_attribute_patched
      @am_attribute_patched = true
      return unless defined?(::ActiveModel::Attribute)
      ::ActiveModel::Attribute.include(::RactorRailsShim::ActiveModelAttributePatch)
      if defined?(::ActiveModel::AttributeRegistration) &&
         ::ActiveModel::AttributeRegistration.const_defined?(:ClassMethods)
        ::ActiveModel::AttributeRegistration::ClassMethods.prepend(
          ::RactorRailsShim::ActiveModelAttributeRegistrationPatch
        )
      end
      if defined?(::ActiveRecord::Attributes) &&
         ::ActiveRecord::Attributes.const_defined?(:ClassMethods)
        ::ActiveRecord::Attributes::ClassMethods.prepend(
          ::RactorRailsShim::ActiveRecordAttributesPatch
        )
      end
      if defined?(::ActiveRecord::ModelSchema) &&
         ::ActiveRecord::ModelSchema.const_defined?(:ClassMethods)
        ::ActiveRecord::ModelSchema::ClassMethods.prepend(
          ::RactorRailsShim::ActiveRecordModelSchemaPatch
        )
      end
    end

    # The shim's make_app_shareable! replaces Concurrent::Map instance variables
    # (which are not Ractor-shareable) with plain Hashes so workers can read
    # them. But Rails code calls Concurrent::Map#compute_if_absent on these
    # caches (e.g. ActiveModel::AttributeMethods' attribute_method_patterns_
    # cache). Plain Hash lacks that method, so we add a compatible definition.
    #
    # Semantics MUST match Concurrent::Map#compute_if_absent exactly:
    #   - if the key is present (even with a nil value), return the stored
    #     value WITHOUT invoking the block;
    #   - otherwise invoke the block, STORE the result (including nil), and
    #     return it.
    # The nil-storing behaviour is load-bearing: Concurrent::Map stores nil
    # results so the block doesn't re-run; the original shim implementation
    # used `IES[key] ||= yield` in the frozen branch, which SKIPS nil — a
    # divergent semantics that re-invokes the block on every lookup for any
    # cache slot whose computed value is nil.
    #
    # For a MUTABLE cache the shim freezes the replaced Hash (so it is shareable
    # across workers); mutating it would raise FrozenError. So when the receiver
    # is frozen we route the store to per-Ractor IES keyed by the Hash identity
    # and the key — giving each worker its own cache entry without mutating the
    # shared object. The frozen branch mirrors the mutable one: check presence
    # first (via IES key?), invoke the block only on miss, store the result
    # (including nil) via IES[]=.
    def _install_hash_compute_if_absent_patch
      return @hash_compute_if_absent_patched if defined?(@hash_compute_if_absent_patched) && @hash_compute_if_absent_patched
      @hash_compute_if_absent_patched = true
      return if ::Hash.method_defined?(:compute_if_absent)
      ::Hash.prepend(Module.new do
        def compute_if_absent(key)
          if frozen?
            # Check the receiver first — a present key (even nil-valued)
            # returns without invoking the block, matching Concurrent::Map.
            return self[key] if key?(key)
            # Per-Ractor IES slot, namespaced by this Hash's object_id so two
            # frozen hashes with the same key don't collide. Use a two-level
            # structure (Hash per receiver) so the presence check (`key?`)
            # and the store share the same slot.
            slot = ActiveSupport::IsolatedExecutionState[:rrs_cia] ||= {}
            bucket = slot[object_id] ||= {}
            return bucket[key] if bucket.key?(key)
            bucket[key] = yield(key)
          elsif key?(key)
            self[key]
          else
            self[key] = yield(key)
          end
        end
      end)
    end

    # Freeze (make Ractor-shareable) every instance variable on every ActiveRecord
    # model class in the MAIN Ractor, before the graph is frozen. Many AR model
    # classes cache unshareable values in class-level ivars (@pending_attribute_
    # modifications, @column_defaults, @symbol_column_to_string_name_hash,
    # Freeze (make Ractor-shareable) unshareable class-level instance variables
    # on ActiveRecord model classes. Delegates to
    # RactorRailsShim::Freezers::ClassIvarFreezer (extracted Issue #1); kept as
    # a facade method for the existing prepare_for_ractors! call site and the
    # naming-convention spec. See ClassIvarFreezer for the contract.
    def _freeze_active_record_class_ivars!
      RactorRailsShim::Freezers::ClassIvarFreezer.call
    end

    # Freeze (make Ractor-shareable) unshareable class-level ivars on GLOBAL
    # classes (Time/Date timezone caches, I18n locale caches, ...). Delegates
    # to RactorRailsShim::Freezers::GlobalClassIvarFreezer (extracted Issue #1);
    # kept as a facade method for prepare_for_ractors! and the naming-convention
    # spec. See GlobalClassIvarFreezer for the contract.
    def _freeze_global_class_ivars!
      RactorRailsShim::Freezers::GlobalClassIvarFreezer.call
    end

    # Replace GLOBAL constants that hold non-shareable values (e.g.
    # Time/Date/DateTime::DATE_FORMATS contain Proc values) with frozen,
    # shareable equivalents. Delegates to
    # RactorRailsShim::Freezers::GlobalConstantFreezer (extracted Issue #1);
    # kept as a facade method for prepare_for_ractors! and the naming-convention
    # spec. See GlobalConstantFreezer for the contract.
    def _freeze_global_constants!
      RactorRailsShim::Freezers::GlobalConstantFreezer.call
    end

    # ActiveSupport::Messages::Metadata holds non-shareable Array constants
    # (ENVELOPE_SERIALIZERS / TIMESTAMP_SERIALIZERS) of serializer Modules.
    # Delegates to RactorRailsShim::Freezers::MessagesConstantsFreezer
    # (extracted Issue #1); kept as a facade method for prepare_for_ractors!
    # and the naming-convention spec. See MessagesConstantsFreezer for the
    # contract (incl. the msgpack pre-check and the load-order invariant).
    def _freeze_messages_constants!
      RactorRailsShim::Freezers::MessagesConstantsFreezer.call
    end

    # Warm ActiveRecord model classes' lazily-computed, shareable class-ivar
    # memoizations in the MAIN Ractor, BEFORE the graph is frozen. Methods like
    # the timestamp_attribute_* helpers cache frozen Arrays of strings (shareable
    # once warmed), so pre-populating them here lets workers read via `||=`
    # without ever setting the class ivar. (Class ivars holding unshareable
    # values are handled by _freeze_active_record_class_ivars!.)
    # Delegates to RactorRailsShim::Freezers::CacheWarmer (extracted Issue #1);
    # kept as a facade method for the existing prepare_for_ractors! call site
    # and the naming-convention spec.
    def _warm_active_record_class_caches!
      RactorRailsShim::Freezers::CacheWarmer.call
    end
  end
end
