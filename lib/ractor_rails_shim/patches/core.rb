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
  # mattr-definition time (boot, in main). The mattr reader (string-eval'd)
  # looks the default up here by key — we CANNOT inline arbitrary default
  # values into the eval'd method body (a Logger's `.inspect` is
  # `#<Logger:...>`, invalid Ruby). Read by workers when both their IES slot
  # and SHAREABLE_FALLBACK are empty. NOT made shareable (some defaults like
  # Logger are intrinsically unshareable); workers only reach here if the
  # value is a simple shareable literal (Symbol/String/Integer), in which
  # case reading the constant is fine because... actually it IS a constant
  # holding an unshareable Hash → worker read would raise. So this registry is
  # ONLY safe to read from workers for shareable defaults. We guard the reader
  # to only consult it for defaults that are Ractor.shareable?.
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

  # Versions each patch was tested against. Populated by the install_*
  # methods as they register themselves. A patch applies to a runtime Rails
  # version only if the runtime segment matches one of its tested entries.
  # This is the "load different patches for different Rails versions"
  # infrastructure: to add 7.x support, write version-specific variants and
  # tag them here. Defined on the module (not the singleton class) so it's
  # readable from outside as RactorRailsShim::PATCH_VERSIONS.
  PATCH_VERSIONS = {}

  # Raised under :strict version policy when the runtime Rails/Ruby version
  # isn't in the tested set. Defined on the module so it's catchable as
  # RactorRailsShim::UnsupportedVersionError.
  class UnsupportedVersionError < StandardError; end

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
    # Defaults to :warn when never explicitly set.
    def version_policy
      @version_policy || :warn
    end
    attr_writer :version_policy

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
    # Set explicitly via RactorRailsShim.thread_mode = true, or implicitly from
    # ENV["SERVER"] (puma|falcon|thin|webrick|thread*). Detected in install.
    def thread_mode?
      return @thread_mode if defined?(@thread_mode)
      false
    end

    attr_writer :thread_mode

    def install
      _check_version_support
      @thread_mode = !!(ENV["SERVER"] && ENV["SERVER"] =~ /puma|falcon|thin|webrick|thread/i) unless defined?(@thread_mode)

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
    # whole constant-shareability machinery is owned by core.rb.

    def shareable_constants
      SHAREABLE_CONSTANTS
    end

    def install_shareable_constants
      # Called at install time; if ActiveSupport isn't loaded yet, the
      # constants don't exist. We re-run from patch_rails_module! (which
      # fires once Rails — and thus ActiveSupport — is defined). Guarded
      # by @shareable_constants_done so both paths are safe.
      _register_patch :shareable_constants, "8.1"
      return unless defined?(::ActiveSupport)

      do_install_shareable_constants
    end

    # Run after Rails is fully booted (after Rails.application.initialize!)
    # and BEFORE spawning worker Ractors. Re-attempts to make every
    # registered constant shareable; constants that didn't exist at install
    # time (e.g. Rails::Railtie, loaded after `module Rails` opens) get
    # fixed here. Safe to call multiple times; already-shareable constants
    # are no-ops.
    #
    # This MUST run in the main Ractor (const_set writes the constant table).
    # Public wrapper is `prepare_for_ractors!` above.
    def do_install_shareable_constants
      shareable_constants.each { |path| make_constant_shareable(path) }
    end

    # Resolve a constant path string to a value, and if it exists and is
    # not already shareable, replace it with its shareable (deep-frozen)
    # version. Returns true if the constant was made shareable (or already
    # was); false if it doesn't exist yet (caller may retry).
    def make_constant_shareable(const_path)
      owner, name = split_const_path(const_path)
      return false unless owner && name
      return true if owner.const_defined?(name, false) == false

      val = owner.const_get(name, false)
      return true if Ractor.shareable?(val)

      shareable = _make_value_shareable(val)
      return true unless shareable

      # Deep-freeze and reassign. Ractor.make_shareable mutates `val` in
      # place (freezing it and its reachable objects) and returns it.
      # const_set warns "already initialized constant" because Rails'
      # environment_inquirer.rb defined the constant first. The reassign is
      # intentional (we're replacing the mutable value with its frozen
      # shareable twin), so silence that one warning.
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        owner.const_set(name, shareable)
      ensure
        $VERBOSE = verbose
      end
      true
    end

    # Best-effort shareable replacement for a constant value. Monitor/Mutex
    # become a NoOpLock (never contended post-boot). BasicObject instances
    # (used as sentinel sentinels, e.g. PRIMARY_KEY_NOT_SET) can't be frozen
    # (BasicObject has no #freeze method) — replace with a frozen Symbol.
    # Everything else is deep-frozen via Ractor.make_shareable; if that fails
    # (e.g. a Proc, or a Concurrent::Map / TypeMap holding Procs — both
    # intrinsically unshareable and needing upstream Rails changes), returns
    # nil and the constant is left as-is (the worker will raise a clear
    # IsolationError on read).
    def _make_value_shareable(val)
      if (val.is_a?(::Monitor) rescue false) || (val.is_a?(::Mutex) rescue false)
        Ractor.make_shareable(NoOpLock.new)
      elsif !(val.respond_to?(:freeze) rescue false)
        # BasicObject subclasses don't have #freeze/#respond_to? (Kernel not
        # included). Replace with a frozen Symbol sentinel — it's compared
        # with `equal?`, and a frozen Symbol is always shareable.
        Ractor.make_shareable(:"__shim_unshareable_sentinel__")
      else
        begin
          Ractor.make_shareable(val)
        rescue => e
          nil
        end
      end
    end

    # Split "A::B::C" into [A::B (module), :C]. Returns [nil, nil] if the
    # parent isn't defined.
    def split_const_path(path)
      parts = path.split("::")
      return [Object, parts.first.to_sym] if parts.size == 1
      parent = parts[0...-1].inject(Object) { |ns, n| ns.const_get(n) } rescue nil
      return [nil, nil] unless parent
      [parent, parts.last.to_sym]
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
      do_install_shareable_constants
      RactorRailsShim._freeze_shareable_class_ivars! if RactorRailsShim.respond_to?(:_freeze_shareable_class_ivars!)
      snapshot_gem_paths!
      snapshot_query_logs!
      _install_rack_request_patch
      _install_inflector_patch
      _install_module_introspection_patch
      _install_parameter_encoding_patch
      _install_path_registry_patch
      _install_action_view_resolver_patch
      _install_action_view_partial_path_patch
      _install_action_view_field_type_patch
      _install_action_view_safe_join_patch
      _install_abstract_controller_patch
      _install_action_controller_controller_name_patch
      _install_flash_helpers_patch
      _install_csrf_reset_patch
      _install_active_support_error_reporter_patch
      _install_lookup_context_patch
      _install_i18n_patch
      _install_i18n_backend_patch
      _install_i18n_interpolation_patch
      _install_messages_serializer_patch
      _install_template_handlers_patch
      _install_execution_context_patch
      _install_request_parameter_parsers_patch
      _install_query_parser_patch
      _install_rack_utils_patch
      _install_log_subscriber_patch
      _install_local_cache_patch
      _install_reloader_patch
      _install_exception_wrapper_patch
      _install_action_dispatch_routing_patch
      _install_action_dispatch_mounted_helpers_patch
      _install_action_dispatch_http_url_patch
      _install_journey_routes_patch
      _install_warden_hooks_patch
      _install_warden_strategies_patch
      _install_devise_failure_app_patch
      _install_csrf_reset_patch
      _install_activerecord_connection_handler_patch
      _install_activerecord_configurations_patch
      _install_activerecord_db_config_handlers_patch
      _install_activerecord_query_transformers_patch
      _install_activerecord_module_attrs_patch
      _install_activerecord_deduplicable_patch
      _install_activerecord_pool_config_patch
      _install_activerecord_reaper_patch
      _install_arel_visitor_dispatch_cache_patch
      _install_arel_bind_block_patch
      _install_activerecord_quoting_cache_patch
      _install_activerecord_serialize_cast_value_patch
      _install_activerecord_delegation_patch
      _install_activerecord_primary_key_patch
      _install_activerecord_query_constraints_patch
      _install_activerecord_relation_delegate_cache_patch
      _install_activerecord_model_classes_patch
      _install_active_model_naming_patch
      _install_active_record_core_patch
      _install_active_record_inheritance_patch
      _install_active_record_model_schema_patch
      _install_activerecord_model_schema_patch
      _install_activerecord_delegation_patch
      _install_openssl_digest_patch
      _install_caching_key_generator_patch
      _install_active_model_conversion_patch
      _install_activerecord_find_by_cache_patch
      _install_activerecord_migration_patch
      _install_activerecord_transaction_callbacks_patch
      _install_activerecord_query_logs_patch
      _install_kaminari_config_patch
      _install_propshaft_patch
      _install_messages_serializer_patch
      _install_devise_url_helpers_patch
      _install_devise_authenticatable_patch
      _install_polymorphic_routes_patch
      install_url_helpers_patch
      fix_url_helpers_singleton_routes
      _install_orm_adapter_patch
      _install_warden_serializer_patch
      _install_json_encoding_patch
      _install_active_model_attribute_patch
      _install_hash_compute_if_absent_patch
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
      @version_policy ||= :warn
      unless RactorRailsShim::Version.supported_ruby?
        msg = "ractor-rails-shim: Ruby #{RUBY_VERSION} — shim developed " \
              "against Ruby #{SUPPORTED_RUBY}. Ractor semantics may differ; " \
              "the shim may break. Proceeding anyway."
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
    def _version_mismatch(message)
      case version_policy
      when :strict
        raise UnsupportedVersionError, message
      when :off
        # silent
      else
        warn message
      end
    end

    # Report which registered patches apply to the runtime Rails version
    # (and which were skipped because they're untested on it). Useful for
    # diagnostics and CI. Returns a Hash: { applied: [...], skipped: [...] }.
    def applicable_patches
      seg = RactorRailsShim::Version.rails_segment
      applied = []
      skipped = []
      PATCH_VERSIONS.each do |name, tested|
        if seg.nil? || tested.include?(seg)
          applied << name
        else
          skipped << { name: name, tested: tested, runtime: seg }
        end
      end
      { applied: applied, skipped: skipped }
    end

    # Record that a patch was developed/tested against the given Rails version
    # segments. Called by each install_* method. This populates PATCH_VERSIONS
    # so `applicable_patches` can report what applied to the runtime. To add
    # support for a new version, add the segment here (after writing/testing
    # the variant) — no other wiring needed.
    def _register_patch(name, *tested_segments)
      existing = PATCH_VERSIONS[name] || []
      PATCH_VERSIONS[name] = (existing + tested_segments).uniq
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
    def capture_app_constants
      map = {}
      return map unless defined?(::Rails) && Rails.respond_to?(:autoloaders)
      [Rails.autoloaders.main, Rails.autoloaders.once].each do |loader|
        next unless loader.respond_to?(:all_expected_cpaths)
        begin
          loader.all_expected_cpaths.values.each do |cpath|
            obj = Object.const_get(cpath) rescue next
            begin
              Ractor.make_shareable(obj) unless Ractor.shareable?(obj)
            rescue
              next
            end
            map[cpath] = obj if Ractor.shareable?(obj)
          end
        rescue => e
          warn "[ractor_rails_shim] capture_app_constants: #{e.class}: #{e.message}"
        end
      end
      map.freeze
    end

    # Build the shareable Rack app handed to kino. Captures the application's
    # constants in the main Ractor and wraps the frozen, shareable app in a
    # WorkerApp that rebinds those constants (and initializes the worker's
    # ActiveRecord connection) on the first request served by each worker
    # Ractor. Returns a shareable WorkerApp instance.
    def worker_app(frozen_app)
      bindings = capture_app_constants
      WorkerApp.new(frozen_app, bindings)
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
    # For a MUTABLE cache the shim freezes the replaced Hash (so it is shareable
    # across workers); mutating it would raise FrozenError. So when the receiver
    # is frozen we route the store to per-Ractor IES keyed by the Hash identity
    # and the key — giving each worker its own cache entry without mutating the
    # shared object. Semantics otherwise match Concurrent::Map.
    def _install_hash_compute_if_absent_patch
      return @hash_compute_if_absent_patched if defined?(@hash_compute_if_absent_patched) && @hash_compute_if_absent_patched
      @hash_compute_if_absent_patched = true
      return if ::Hash.method_defined?(:compute_if_absent)
      ::Hash.prepend(Module.new do
        def compute_if_absent(key)
          if frozen?
            ies_key = :"rrs_cia_#{object_id}_#{key}"
            ActiveSupport::IsolatedExecutionState[ies_key] ||= yield(key)
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
    # @yaml_encoder, @dangerous_attribute_methods, ...). A worker Ractor cannot
    # read an unshareable class-ivar value (Ractor::IsolationError) nor set one.
    # Freezing them in main (where setting is allowed) yields shareable values
    # that workers read without writing. AR Type objects freeze cleanly, so this
    # is behavior-preserving; per-request code never mutates model class ivars.
    def _freeze_active_record_class_ivars!
      return unless defined?(::ActiveRecord::Base)
      models = [::ActiveRecord::Base] + (::ActiveRecord::Base.descendants rescue [])
      models.each do |klass|
        # NOTE: do NOT skip abstract classes (e.g. a primary_abstract_class
        # ApplicationRecord). Workers recurse into them via
        # apply_pending_attribute_modifications, so their class ivars must also
        # be shareable.
        klass.instance_variables.each do |ivar|
          val = klass.instance_variable_get(ivar)
          next if val.nil? || Ractor.shareable?(val)
          begin
            Ractor.make_shareable(val)
          rescue
            nil
          end
        end
      end
    end

    # Freeze (make Ractor-shareable) unshareable class-level ivars on GLOBAL
    # classes (Time/Date timezone caches, I18n locale caches, ...) in the MAIN
    # Ractor, before the graph is frozen. Unlike model classes, these are shared
    # singletons whose class ivars (e.g. Time's @zone_default / @zone_cache) hold
    # unshareable values that a worker Ractor would otherwise fail to read
    # (Ractor::IsolationError). Freezing them in main yields shareable values.
    def _freeze_global_class_ivars!
      classes = %w[Time Date DateTime I18n].filter_map { |n| Object.const_get(n) rescue nil }
      classes.each do |klass|
        klass.instance_variables.each do |ivar|
          val = klass.instance_variable_get(ivar)
          next if val.nil? || Ractor.shareable?(val)
          begin
            Ractor.make_shareable(val)
          rescue
            nil
          end
        end
      end
    end

    # Replace GLOBAL constants that hold non-shareable values (e.g.
    # Time/Date/DateTime::DATE_FORMATS contain Proc values) with frozen,
    # shareable equivalents so worker Ractors can read them. Proc-valued format
    # entries are dropped (to_fs falls back to to_s for those formats). This is
    # done in the MAIN Ractor, where const_set is allowed.
    def _freeze_global_constants!
      constants = %w[Time Date DateTime].filter_map do |n|
        mod = Object.const_get(n) rescue nil
        mod.is_a?(Module) ? [mod, :DATE_FORMATS] : nil
      end
      constants.each do |mod, name|
        next unless mod.const_defined?(name, false)
        val = mod.const_get(name, false)
        next if Ractor.shareable?(val)
        shareable = if val.is_a?(Hash)
          h = {}
          val.each { |k, v| h[k] = v if Ractor.shareable?(v) }
          h.freeze
        elsif val.is_a?(Array)
          val.select { |v| Ractor.shareable?(v) }.freeze
        else
          val
        end
        begin
          mod.const_set(name, shareable)
        rescue
          nil
        end
      end
    end

    # ActiveSupport::Messages::Metadata holds non-shareable Array constants
    # (ENVELOPE_SERIALIZERS / TIMESTAMP_SERIALIZERS) of serializer Modules, used
    # by MessageEncryptor during flash/session cookie serialization. A worker
    # Ractor reading these constants (e.g. on `redirect_to`, which encrypts a
    # flash message) raises Ractor::IsolationError. The Arrays are shareable once
    # frozen (their elements are Modules), so deep-freeze and const_set the
    # shareable copy back so workers read a shareable constant.
    def _freeze_messages_constants!
      # Load ActiveSupport::MessagePack in the MAIN Ractor FIRST. metadata.rb
      # registers an `ActiveSupport.on_load(:message_pack)` callback that mutates
      # ENVELOPE_SERIALIZERS / TIMESTAMP_SERIALIZERS via `<<`. If that callback
      # first fires inside a worker Ractor (which happens the first time a
      # cookie's `detect_format` probes MessagePackWithFallback.dumped?, because
      # it lazily requires "active_support/message_pack"), it runs against the
      # already-frozen arrays below and raises
      #   FrozenError: can't modify frozen Array
      # Loading here makes the callback fire once, in main, against the
      # non-frozen arrays; load hooks never fire again in workers.
      # Gem::LoadError is a ScriptError (not StandardError), so a bare
      # `rescue nil` on the require would NOT catch a missing msgpack gem.
      begin
        require "active_support/message_pack"
      rescue LoadError
        return
      end

      mod = (Object.const_get(:ActiveSupport) rescue nil)&.const_get(:Messages, false) rescue nil
      mod = mod&.const_get(:Metadata, false) rescue nil
      return unless mod.is_a?(Module)
      %i[ENVELOPE_SERIALIZERS TIMESTAMP_SERIALIZERS].each do |name|
        next unless mod.const_defined?(name, false)
        val = mod.const_get(name, false)
        next if Ractor.shareable?(val)
        shareable = Ractor.make_shareable(val) rescue val
        begin
          mod.const_set(name, shareable)
        rescue
          nil
        end
      end
    end

    # Warm ActiveRecord model classes' lazily-computed, shareable class-ivar
    # memoizations in the MAIN Ractor, BEFORE the graph is frozen. Methods like
    # the timestamp_attribute_* helpers cache frozen Arrays of strings (shareable
    # once warmed), so pre-populating them here lets workers read via `||=`
    # without ever setting the class ivar. (Class ivars holding unshareable
    # values are handled by _freeze_active_record_class_ivars!.)
    def _warm_active_record_class_caches!
      return unless defined?(::ActiveRecord::Base)
      models = [::ActiveRecord::Base] + (::ActiveRecord::Base.descendants rescue [])
      warmers = %i[
        timestamp_attributes_for_create_in_model
        timestamp_attributes_for_update_in_model
        all_timestamp_attributes_in_model
        sequence_name
        columns
        column_names
        attribute_names
        column_defaults
        symbol_column_to_string_name_hash
        returning_columns_for_insert
        yaml_encoder
        attribute_types
      ]
      models.each do |klass|
        next if klass.abstract_class?
        warmers.each do |m|
          next unless klass.respond_to?(m, true)
          begin
            klass.send(m)
          rescue
            nil
          end
        end
      end
    end
  end
  # A shareable Rack wrapper that performs per-worker initialization lazily,
  # inside the worker Ractor's request path (kino's :ractor mode has no
  # per-worker init hook). On the first request served by a worker it:
  #
  #   1. rebinds the captured application constants into that worker's
  #      namespace (so bare `Post` etc. resolve), then
  #   2. ensures the worker's ActiveRecord connection handler is initialized.
  #
  # The wrapper holds only shareable state (@app, @bindings), so the instance
  # is Ractor.make_shareable. `Ractor.current` provides per-worker storage for
  # the one-time guard, avoiding any top-level constant reference.
  class WorkerApp
    def initialize(app, bindings)
      @app = app
      @bindings = bindings
    end

    def call(env)
      setup_once!
      @app.call(env)
    end

    private

    def setup_once!
      return if Ractor.current[:rrs_worker_ready]
      rebind_constants
      RactorRailsShim.init_worker_ar_connections! if defined?(RactorRailsShim)
      Ractor.current[:rrs_worker_ready] = true
    end

    def rebind_constants
      @bindings.each do |cpath, obj|
        parent = Object
        parts = cpath.split("::")
        parts[0...-1].each do |p|
          parent = if parent.const_defined?(p, false)
                     parent.const_get(p, false)
                   else
                     parent.const_set(p, Module.new)
                   end
        end
        leaf = parts.last
        parent.const_set(leaf, obj) unless parent.const_defined?(leaf, false)
      end
    end
  end
end
