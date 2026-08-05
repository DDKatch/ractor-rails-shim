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

  # The nine shared registries. Issue #35 (Round 4): storage OWNS the mutable
  # registries (Array/Hash) — the facade constants below are the SAME object
  # as Registry's instance variables, so appends are visible through both
  # paths. The frozen (shareable) registries are swapped via
  # `_reassign_shareable_const` which updates BOTH the facade constant (for
  # the string-eval'd code that reads `RactorRailsShim::SHAREABLE_FALLBACK`)
  # and Registry (so role objects that read `Registry.shareable_fallback`
  # see the new value). New code should prefer `RactorRailsShim::Registry`.
  CLASS_ATTRIBUTES = Registry.class_attributes
  MATTR_DEFAULTS = Registry.mattr_defaults
  CLASS_ATTR_VALUES = Registry.class_attr_values
  SHAREABLE_MATTR_DEFAULTS = Registry.shareable_mattr_defaults
  SHAREABLE_CONSTANTS = Registry.shareable_constants
  SHAREABLE_CLASS_IVARS = Registry.shareable_class_ivars
  ABSTRACT_REGISTRY = Registry.abstract_registry
  VIEW_CONTEXT_REGISTRY = Registry.view_context_registry
  SHAREABLE_FALLBACK = Registry.shareable_fallback

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
    # Delegates to RactorRailsShim::Funnel (extracted Issue #31, step
    # 31.1d).
    def debug?
      Funnel.debug?
    end

    def debug=(value)
      Funnel.debug = value
    end

    # Swallow an exception raised by the block, optionally logging it when
    # `debug?` is on. Used by freeze/shareability paths where individual
    # failures are expected (some ivars hold intrinsically unshareable
    # values like Procs) but a worker crash on the same value later has no
    # visible cause. `label` identifies the call site (e.g. "freeze AR ivar
    # Post@column_defaults"). Keep the label short — it's only for grepping.
    # Delegates to RactorRailsShim::Funnel.swallow (extracted Issue #31,
    # step 31.1d).
    def _swallow(label)
      Funnel.swallow(label) { yield }
    end

    # Reassign a constant on RactorRailsShim with a new shareable value,
    # silencing the "already initialized constant" warning that const_set
    # emits when the constant was previously defined. Centralizes the
    # $VERBOSE-suppressed const_set dance that was repeated at every
    # shareable-constant rebuild site (SHAREABLE_FALLBACK,
    # SHAREABLE_MATTR_DEFAULTS, etc.). The value MUST already be frozen +
    # shareable — this method does not make it so.
    #
    # Issue #35 (Round 4): for the four frozen registries that Registry
    # owns (SHAREABLE_FALLBACK, SHAREABLE_MATTR_DEFAULTS,
    # ABSTRACT_REGISTRY, VIEW_CONTEXT_REGISTRY), also update the
    # Registry instance variable so role objects reading through
    # `Registry.*` see the new value. The facade const_set is kept for
    # the string-eval'd code that reads `RactorRailsShim::SHAREABLE_*`.
    def _reassign_shareable_const(name, value)
      verbose, $VERBOSE = $VERBOSE, nil
      begin
        const_set(name, value)
      ensure
        $VERBOSE = verbose
      end
      case name
      when :SHAREABLE_FALLBACK then Registry.reassign_shareable_fallback(value)
      when :SHAREABLE_MATTR_DEFAULTS then Registry.reassign_shareable_mattr_defaults(value)
      when :ABSTRACT_REGISTRY then Registry.reassign_abstract_registry(value)
      when :VIEW_CONTEXT_REGISTRY then Registry.reassign_view_context_registry(value)
      end
      value
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
      # `storage_strategy` derives lazily from `RunMode.thread?` (see
      # `StorageStrategy`), so no explicit sync here — resetting `RunMode`
      # is enough to reset the strategy.
    end

    # Install all the patches. Safe to call multiple times (idempotent).
    # Delegates to Installer.install (extracted Issue #13, Step 13.6). See
    # Installer for the orchestration contract (version check, run-mode
    # resolve, branch by mode, early-boot install_* calls).
    def install
      Installer.install
    end

    def installed?
      Installer.installed?
    end

    # --- Generic constant-sharing utilities (moved from rails_module.rb) -----
    # These are framework-agnostic; SHAREABLE_CONSTANTS lives here too, so the
    # whole constant-shareability machinery is owned by core.rb. The machinery
    # itself is extracted to RactorRailsShim::ConstantShareabilizer (Issue #13,
    # Step 13.1); the methods below are facade delegations preserving the
    # existing public/private API and the naming-convention / shim / safe_const
    # _get / make_value_shareable specs.

    # Public reader for the SHAREABLE_CONSTANTS registry. Users register
    # their own constants via `RactorRailsShim.shareable_constants << "MyGem::LIST"`.
    # Delegates to ConstantShareabilizer.shareable_constants (which reads
    # RactorRailsShim::SHAREABLE_CONSTANTS).
    def shareable_constants
      ConstantShareabilizer.shareable_constants
    end

    # Resolve a constant path string to a value, and if it exists and is
    # not already shareable, replace it with its shareable (deep-frozen)
    # version. Returns true if the constant was made shareable (or already
    # was); false if it doesn't exist yet (caller may retry). Delegates to
    # ConstantShareabilizer.make_shareable! (extracted Issue #13, Step 13.1).
    def make_constant_shareable!(const_path)
      ConstantShareabilizer.make_shareable!(const_path)
    end

    # _install_*_patch methods called from OTHER install paths, not from the
    # dispatcher. The constant + the dispatcher live on Installer (extracted
    # Issue #13, Step 13.6); kept as a facade delegation so the existing
    # framework_patch_dispatch_spec (which reads the dispatcher's source
    # location) and version_spec keep passing. See Installer for the contract.
    NON_DISPATCHED_FRAMEWORK_PATCHES = RactorRailsShim::Installer::NON_DISPATCHED_FRAMEWORK_PATCHES

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
      ConstantShareabilizer.apply!
      Freezers::ShareableClassIvarFreezer.call
      snapshot_gem_paths!
      snapshot_query_logs!
      Installer.dispatch_all_framework_patches
      install_url_helpers_patch
      fix_url_helpers_singleton_routes!
      Freezers::CacheWarmer.call
      Freezers::ClassIvarFreezer.call
      Freezers::GlobalClassIvarFreezer.call
      Freezers::GlobalConstantFreezer.call
      Freezers::MessagesConstantsFreezer.call
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
    # WorkerAppFactory.capture_constants! (extracted Issue #13, Step 13.4;
    # WorkerApp moved to ractor_rails_shim/worker_app.rb). See
    # WorkerAppFactory for the contract (Zeitwerk introspection, the
    # non-Zeitwerk guard, and why the captured map is needed for worker
    # constant rebinding).
    def capture_app_constants!
      WorkerAppFactory.capture_constants!
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
    # Delegates to `RactorRailsShim::Patches::ActiveModelAttribute.install`
    # (extracted Step 22.2, Issue #22). The idempotency flag now lives on the
    # role object. See `Patches::ActiveModelAttribute` for the contract (the
    # three prepend targets + the ActiveModel::Attribute guard).
    def _install_active_model_attribute_patch
      Patches::ActiveModelAttribute.install
    end

    # The shim's make_app_shareable! replaces Concurrent::Map instance variables
    # (which are not Ractor-shareable) with plain Hashes so workers can read
    # them. But Rails code calls Concurrent::Map#compute_if_absent on these
    # caches (e.g. ActiveModel::AttributeMethods' attribute_method_patterns_
    # cache). Plain Hash lacks that method, so we add a compatible definition.
    # See `RactorRailsShim::Patches::HashComputeIfAbsent` for the full
    # semantics contract (nil-storing, per-Hash IES isolation via object_id).
    # Install the `Hash#compute_if_absent` patch. Delegates to
    # `RactorRailsShim::Patches::HashComputeIfAbsent.install` (extracted
    # Step 22.1, Issue #22); kept as a facade method so the existing
    # framework_patch_dispatch auto-discovery (which enumerates
    # `_install_*_patch` singleton methods), `compute_if_absent_spec.rb`,
    # and `storage_spec.rb` keep passing. The idempotency flag now lives
    # on the role object. See `Patches::HashComputeIfAbsent` for the
    # contract (mutable vs frozen receiver, nil-storing, per-Hash IES
    # isolation via object_id).
    def _install_hash_compute_if_absent_patch
      Patches::HashComputeIfAbsent.install
    end

    # The freezer delegations (_freeze_active_record_class_ivars!,
    # _freeze_global_class_ivars!, _freeze_global_constants!,
    # _freeze_messages_constants!, _warm_active_record_class_caches!)
    # were deleted in Issue #31. prepare_for_ractors! calls the role objects
    # (Freezers::ClassIvarFreezer.call, Freezers::GlobalClassIvarFreezer.call,
    # Freezers::GlobalConstantFreezer.call, Freezers::MessagesConstantsFreezer.call,
    # Freezers::CacheWarmer.call) directly. See freezers.rb for the contracts.
  end
end
