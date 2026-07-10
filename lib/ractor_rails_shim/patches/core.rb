# frozen_string_literal: true

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

    # Policy for version mismatches. One of :warn (default), :strict, :off.
    # Set before `install`:
    #   RactorRailsShim.version_policy = :strict
    attr_accessor :version_policy

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
    def install
      _check_version_support
      install_mattr_accessor
      install_class_attribute
      install_zeitwerk_registry
      install_rails_module
      install_shareable_constants
      install_execution_wrapper
      @installed = true
      true
    end

    def installed?
      @installed ||= false
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
      _install_rack_request_patch
      _install_inflector_patch
      _install_parameter_encoding_patch
      _install_path_registry_patch
      _install_action_view_resolver_patch
      _install_action_view_partial_path_patch
      _install_action_view_field_type_patch
      _install_action_view_safe_join_patch
      _install_abstract_controller_patch
      _install_action_controller_controller_name_patch
      _install_active_support_error_reporter_patch
      _install_lookup_context_patch
      _install_i18n_patch
      _install_template_handlers_patch
      _install_execution_context_patch
      _install_request_parameter_parsers_patch
      _install_rack_utils_patch
      _install_log_subscriber_patch
      _install_exception_wrapper_patch
      _install_action_dispatch_routing_patch
      _install_action_dispatch_mounted_helpers_patch
      _install_warden_hooks_patch
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
      _install_activerecord_model_schema_patch
      _install_active_model_conversion_patch
      _install_activerecord_find_by_cache_patch
      _install_kaminari_config_patch
      _install_propshaft_patch
      _install_devise_url_helpers_patch
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
  end
end
