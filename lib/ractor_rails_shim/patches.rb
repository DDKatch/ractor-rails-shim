# frozen_string_literal: true

# The core shim: reroute Rails' class-level instance variable accessors
# through Ractor-safe storage.
#
# Background: Rails stores global state in class ivars:
#
#   class Rails
#     class << self
#       attr_accessor :app_class, :cache, :logger
#       def application; @application ||= ...; end
#     end
#   end
#
# From a non-main Ractor these reads/writes raise Ractor::IsolationError:
#   "can not get unshareable values from instance variables of classes/modules
#    from non-main Ractors"
#
# The fix: store the values in ActiveSupport::IsolatedExecutionState, which
# is already Ractor-safe. It's thread-local storage (Thread.current[:key]),
# and each Ractor has its own threads, so each Ractor gets its own slot.
# Verified on Ruby 4.0.5: a non-main Ractor reads nil for a key the main
# Ractor set, sets its own value without error, and main's value is intact.
#
# IMPORTANT: all method redefinitions use module_eval with STRING, not
# define_method with a block. A block captures the defining Ractor's
# binding, and calling it from another Ractor raises:
#   "defined with an un-shareable Proc in a different Ractor"
# String eval produces methods with no captured binding, callable from any
# Ractor. Verified on Ruby 4.0.5.

begin
  require "active_support/isolated_execution_state"
rescue LoadError
  # ActiveSupport not installed — the fallback below provides the same API.
end
require_relative "fallback_ies"
require_relative "version_check"

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
    SUPPORTED_RUBY = RactorRailsShim::Version::SUPPORTED_RUBY
    SUPPORTED_RAILS = "8.1"
    # Versions each patch was tested against lives on the module as
    # RactorRailsShim::PATCH_VERSIONS (see above) so it's readable from
    # outside the singleton class.

    # Policy for version mismatches. One of :warn (default), :strict, :off.
    # Set before `install`:
    #   RactorRailsShim.version_policy = :strict
    attr_accessor :version_policy

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
    end

    # Patch Rack::Request's class-level attr_accessors (forwarded_priority,
    # x_forwarded_proto_priority) to not read @ivars from a worker Ractor.
    # The values are frozen-Symbol Arrays (shareable); route the cache
    # through IES with the same default in workers. Read per-request via
    # ActionDispatch::RemoteIp. Applied at prepare_for_ractors! time (after
    # Rails boots, so Rack is loaded).
    def _install_rack_request_patch
      return if @rack_request_patched
      @rack_request_patched = true
      _register_patch :rack_request, "8.1"
      return unless defined?(::Rack::Request)
      req = ::Rack::Request
      fp_key = :ractor_rails_shim_rack_forwarded_priority
      xp_key = :ractor_rails_shim_rack_x_forwarded_proto_priority
      fp_key_str = fp_key.inspect
      xp_key_str = xp_key.inspect
      req.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def forwarded_priority
          v = ActiveSupport::IsolatedExecutionState[#{fp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@forwarded_priority)
            @forwarded_priority
          else
            [:forwarded, :x_forwarded]
          end
        end
        def forwarded_priority=(val)
          ActiveSupport::IsolatedExecutionState[#{fp_key_str}] = val
          @forwarded_priority = val if Ractor.main?
          val
        end
        def x_forwarded_proto_priority
          v = ActiveSupport::IsolatedExecutionState[#{xp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@x_forwarded_proto_priority)
            @x_forwarded_proto_priority
          else
            [:proto, :scheme]
          end
        end
        def x_forwarded_proto_priority=(val)
          ActiveSupport::IsolatedExecutionState[#{xp_key_str}] = val
          @x_forwarded_proto_priority = val if Ractor.main?
          val
        end
      RUBY
    end

    # Patch ActiveSupport::Inflector::Inflections to not read @__en_instance__
    # / @__instance__ class ivars from a worker Ractor. The inflections instance
    # holds rules (Arrays/Hashes of Strings) populated at boot; for a frozen
    # shared app it's read-only. Workers share the main-ractor's inflections
    # instance via a shareable fallback (made shareable in place). `instance`
    # / `instance_or_fallback` are called per-request during routing (camelize).
    def _install_inflector_patch
      return if @inflector_patched
      @inflector_patched = true
      _register_patch :inflector, "8.1"
      return unless defined?(::ActiveSupport::Inflector::Inflections)
      inf = ::ActiveSupport::Inflector::Inflections
      en_key = :ractor_rails_shim_inflections_en
      inst_key = :ractor_rails_shim_inflections_instance
      en_key_str = en_key.inspect
      inst_key_str = inst_key.inspect
      inf.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def instance(locale = :en)
          if locale == :en
            v = ActiveSupport::IsolatedExecutionState[#{en_key_str}]
            return v unless v.nil?
            if Ractor.main?
              existing = instance_variable_get(:@__en_instance__) if instance_variable_defined?(:@__en_instance__)
              ActiveSupport::IsolatedExecutionState[#{en_key_str}] = existing
              return existing || new.tap { |i| instance_variable_set(:@__en_instance__, i) }
            end
            fb = RactorRailsShim::SHAREABLE_FALLBACK[#{en_key_str}]
            return fb if fb
            built = new
            ActiveSupport::IsolatedExecutionState[#{en_key_str}] = built
            built
          else
            h = ActiveSupport::IsolatedExecutionState[#{inst_key_str}] ||= (Ractor.main? ? (instance_variable_defined?(:@__instance__) ? instance_variable_get(:@__instance__) : Concurrent::Map.new) : Concurrent::Map.new)
            h[locale] ||= new
          end
        end

        def instance_or_fallback(locale)
          return instance(locale) if locale == :en
          h = ActiveSupport::IsolatedExecutionState[#{inst_key_str}]
          if h && h.key?(locale)
            return h[locale]
          end
          if Ractor.main? && instance_variable_defined?(:@__instance__)
            iv = instance_variable_get(:@__instance__)
            return iv[locale] if iv && iv.key?(locale)
          end
          instance(locale)
        end
      RUBY
      # Register so _build_shareable_fallback! captures the :en inflections
      # instance (made shareable) for workers.
      CLASS_ATTRIBUTES << ["ActiveSupport::Inflector::Inflections", :__en_instance__, en_key, nil]
      # Materialize the :en instance into IES in main so the fallback builder
      # can read + share it.
      inf.instance(:en) if Ractor.main?
    end

    # Patch ActionController::ParameterEncoding::ClassMethods#action_encoding_template
    # to not read @_parameter_encodings (a raw class ivar) from a worker
    # Ractor. The default is an empty-ish Hash; for a frozen shared app workers
    # get an empty frozen Hash (no per-action param encodings — correct for
    # apps that don't declare `parameter_encoding`, e.g. the health controller).
    def _install_parameter_encoding_patch
      return if @param_encoding_patched
      @param_encoding_patched = true
      _register_patch :parameter_encoding, "8.1"
      return unless defined?(::ActionController::ParameterEncoding)
      pe = ::ActionController::ParameterEncoding::ClassMethods
      pe.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def action_encoding_template(action)
          enc = if Ractor.main?
            instance_variable_defined?(:@_parameter_encodings) ? @_parameter_encodings : nil
          else
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_param_encodings]
          end
          if enc && enc.has_key?(action.to_s)
            enc[action.to_s]
          end
        end
      RUBY
    end

    # Patch ActionView::PathRegistry to not read its raw class ivars
    # (@view_paths_by_class, @file_system_resolvers) from a worker Ractor.
    # These are populated at boot (view paths registered by the app). For a
    # frozen shared app they're read-only; workers read them via the shareable
    # fallback (built from main's values, made shareable). `get_view_paths` is
    # called per-request during view lookup; `all_file_system_resolvers` is
    # called by the exception backtrace builder.
    def _install_path_registry_patch
      return if @path_registry_patched
      @path_registry_patched = true
      _register_patch :path_registry, "8.1"
      return unless defined?(::ActionView::PathRegistry)
      pr = ::ActionView::PathRegistry
      vpc_key = :ractor_rails_shim_path_registry_view_paths_by_class
      fsr_key = :ractor_rails_shim_path_registry_file_system_resolvers
      vpc_key_str = vpc_key.inspect
      fsr_key_str = fsr_key.inspect
      pr.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def get_view_paths(klass)
          h = ActiveSupport::IsolatedExecutionState[#{vpc_key_str}]
          h = (Ractor.main? ? (instance_variable_defined?(:@view_paths_by_class) ? instance_variable_get(:@view_paths_by_class) : {}) : RactorRailsShim::SHAREABLE_FALLBACK[#{vpc_key_str}]) if h.nil?
          h[klass] || get_view_paths(klass.superclass)
        end

        def set_view_paths(klass, paths)
          h = ActiveSupport::IsolatedExecutionState[#{vpc_key_str}] ||= (Ractor.main? ? (instance_variable_defined?(:@view_paths_by_class) ? instance_variable_get(:@view_paths_by_class) : {}) : {})
          h[klass] = paths
          instance_variable_set(:@view_paths_by_class, h) if Ractor.main?
        end

        def all_file_system_resolvers
          h = ActiveSupport::IsolatedExecutionState[#{fsr_key_str}]
          h = (Ractor.main? ? (instance_variable_defined?(:@file_system_resolvers) ? instance_variable_get(:@file_system_resolvers) : {}) : RactorRailsShim::SHAREABLE_FALLBACK[#{fsr_key_str}]) if h.nil?
          h.values
        end
      RUBY
      # Register so the fallback builder captures + shares these.
      CLASS_ATTRIBUTES << ["ActionView::PathRegistry", :view_paths_by_class, vpc_key, {}]
      CLASS_ATTRIBUTES << ["ActionView::PathRegistry", :file_system_resolvers, fsr_key, {}]
    end

    # Patch AbstractController::Base.controller_path to not write/read the
    # @controller_path class ivar from a worker Ractor. The original is
    # `@controller_path ||= name.delete_suffix("Controller").underscore` — a
    # raw class-ivar lazy init. The value is a frozen String (shareable). Route
    # through IES; workers compute it from `name` (a class method, no ivar) and
    # cache in their own slot. Read per-request during view lookup.
    def _install_abstract_controller_patch
      return if @abstract_controller_patched
      @abstract_controller_patched = true
      _register_patch :abstract_controller, "8.1"
      return unless defined?(::AbstractController::Base)
      ac = ::AbstractController::Base
      key = :ractor_rails_shim_abstract_controller_path
      key_str = key.inspect

      # Populate the shareable abstract registry from every loaded controller
      # class's @abstract ivar (set by abstract! / inherited at boot). Workers
      # read this via the patched abstract? (per-class values can't live in
      # per-Ractor IES).
      registry = {}
      ac.descendants.each do |klass|
        begin
          registry[klass] = klass.instance_variable_get(:@abstract) if klass.instance_variable_defined?(:@abstract)
        rescue => e
          # ignore — best-effort
        end
      end
      registry[ac] = ac.instance_variable_get(:@abstract) if ac.instance_variable_defined?(:@abstract)
      registry.freeze
      Ractor.make_shareable(registry)
      self._abstract_registry = registry
      ac.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def controller_path
          cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_controller_path_cache] ||= {})
          v = cache[self]
          return v if v
          if Ractor.main? && instance_variable_defined?(:@controller_path)
            v = @controller_path
            cache[self] = v
            return v
          end
          computed = anonymous? ? nil : name.delete_suffix("Controller").underscore
          cache[self] = computed
          computed
        end

        # action_methods: `@action_methods ||= public_instance_methods(true) -
        # internal_methods).map(&:name).to_set` — raw class-ivar lazy init.
        # The value is a Set of Symbols (shareable once frozen). Route through
        # IES; workers compute it from public_instance_methods (no ivar read)
        # and cache in their own slot. Read per-request during dispatch.
        def action_methods
          cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_action_methods_cache] ||= {})
          v = cache[self]
          return v if v
          if Ractor.main? && instance_variable_defined?(:@action_methods)
            v = @action_methods
            cache[self] = v
            return v
          end
          methods = public_instance_methods(true) - internal_methods
          methods.map!(&:name)
          computed = methods.to_set
          cache[self] = computed
          computed
        end

        def clear_action_methods!
          if Ractor.main?
            @action_methods = nil
          end
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_action_methods_cache] = nil
        end

        # abstract! / abstract / abstract? — raw class ivar (@abstract), a
        # per-CLASS boolean. IES is per-Ractor (single value), so we can't use a
        # single IES key for all classes. Instead use a shareable registry
        # (Hash class→bool) built at prepare_for_ractors! time. Workers read
        # the registry; main reads its live @abstract ivar (set by abstract!
        # / inherited). `internal_methods` loops on abstract?.
        def abstract!
          RactorRailsShim._abstract_registry[self] = true if Ractor.main?
          @abstract = true if Ractor.main?
        end

        def abstract
          if Ractor.main? && instance_variable_defined?(:@abstract)
            @abstract
          else
            (RactorRailsShim._abstract_registry || RactorRailsShim::ABSTRACT_REGISTRY)[self] || false
          end
        end
        alias_method :abstract?, :abstract
      RUBY

      # Patch ActionView::ViewPaths::ClassMethods#_prefixes (overrides any
      # Base version). Original: `@_prefixes ||= begin; return local_prefixes
      # if superclass.abstract?; local_prefixes + superclass._prefixes; end`.
      # @_prefixes is a per-CLASS class ivar (workers can't read). Recurse
      # using the patched abstract? and cache in a per-Ractor Hash by class.
      if defined?(::ActionView::ViewPaths::ClassMethods)
        vp = ::ActionView::ViewPaths::ClassMethods
        vp.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def _prefixes
            cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_vp_prefixes_cache] ||= {})
            v = cache[self]
            return v if v
            if Ractor.main? && instance_variable_defined?(:@_prefixes)
              v = @_prefixes
              cache[self] = v
              return v
            end
            computed = if superclass.respond_to?(:abstract?) && superclass.abstract?
              local_prefixes
            elsif superclass.respond_to?(:_prefixes)
              local_prefixes + superclass._prefixes
            else
              local_prefixes
            end
            cache[self] = computed
            computed
          end
        RUBY
      end

      # AbstractController::UrlFor::ClassMethods#action_methods ALSO has a
      # `@action_methods ||= ...` lazy init (it overrides Base.action_methods
      # to subtract route helper names). Patch it the same way.
      if defined?(::AbstractController::UrlFor::ClassMethods)
        url_for_cm = ::AbstractController::UrlFor::ClassMethods
        url_for_cm.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def action_methods
            cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_url_for_action_methods_cache] ||= {})
            v = cache[self]
            return v if v
            if Ractor.main? && instance_variable_defined?(:@action_methods)
              v = @action_methods
              cache[self] = v
              return v
            end
            # NOTE: the original reads `@action_methods ||= if _routes; super -
            # _routes.named_routes.helper_names; else; super; end`. But
            # `_routes` is a singleton method defined via `define_method` with
            # a block (route_set.rb:610), capturing the defining Ractor's
            # binding → "defined with an un-shareable Proc in a different
            # Ractor" when called from a worker. Instead, read the route set
            # directly from the shareable Rails.application (frozen, shared).
            base = super
            routes = Ractor.main? ? (respond_to?(:_routes) ? _routes : nil) : (defined?(::Rails) && ::Rails.application ? ::Rails.application.routes : nil)
            computed = if routes
              base - routes.named_routes.helper_names
            else
              base
            end
            cache[self] = computed
            computed
          end
        RUBY
      end
    end

    # Patch ActiveSupport.error_reporter (and error_reporter=) to not read/write
    # the @error_reporter class ivar from a worker Ractor. The original is an
    # `attr_accessor`-backed class ivar. Route through IES; workers build their
    # own default reporter (which writes to Rails.logger — already per-Ractor).
    def _install_active_support_error_reporter_patch
      return if @error_reporter_patched
      @error_reporter_patched = true
      _register_patch :error_reporter, "8.1"
      return unless defined?(::ActiveSupport)
      key = :ractor_rails_shim_active_support_error_reporter
      key_str = key.inspect
      ::ActiveSupport.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def error_reporter
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@error_reporter)
            @error_reporter
          else
            built = ActiveSupport::ErrorReporter.new
            ActiveSupport::IsolatedExecutionState[#{key_str}] = built
            built
          end
        end
        def error_reporter=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
          @error_reporter = val if Ractor.main?
          val
        end
      RUBY
    end

    # Patch ActionView::LookupContext.registered_details (a singleton
    # attr_accessor backed by @registered_details = []) to not read the class
    # ivar from a worker Ractor. The value is an Array of Symbols
    # (shareable once frozen). Route through IES; workers read the shareable
    # fallback (the boot-time registered details). Read per-request during
    # view lookup (`initialize_details`).
    def _install_lookup_context_patch
      return if @lookup_context_patched
      @lookup_context_patched = true
      _register_patch :lookup_context, "8.1"
      return unless defined?(::ActionView::LookupContext)
      lc = ::ActionView::LookupContext
      key = :ractor_rails_shim_lookup_context_registered_details
      key_str = key.inspect
      lc.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def registered_details
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@registered_details)
            @registered_details
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}] || []
          end
        end
        def registered_details=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
          @registered_details = val if Ractor.main?
          val
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionView::LookupContext", :registered_details, key, []]

      # Patch ActionView::Rendering::ClassMethods#view_context_class to read
      # from a shareable registry (populated in main) instead of building via
      # Class.new{...} blocks (un-shareable Proc from a worker). The built
      # class is made shareable; workers read it via the registry.
      if defined?(::ActionView::Rendering::ClassMethods)
        rcm = ::ActionView::Rendering::ClassMethods

        # Capture the ORIGINAL view_context_class BEFORE patching, so we can
        # build per-controller classes in main using the original logic.
        orig_vcc = rcm.instance_method(:view_context_class)

        # Populate the registry: call the ORIGINAL view_context_class for each
        # loaded controller in main, capture the built class. Done BEFORE
        # patching so ctrl.view_context_class hits the original.
        if Ractor.main?
          registry = {}
          ::AbstractController::Base.descendants.each do |ctrl|
            begin
              vc = orig_vcc.bind(ctrl).call
              registry[ctrl] = vc
            rescue => e
              # skip controllers that can't build (e.g. abstract)
            end
          end
          registry.delete_if { |_, v| v.nil? }
          registry.freeze
          begin
            Ractor.make_shareable(registry)
            self._view_context_registry = registry
          rescue => e
            # If the registry can't be made shareable, leave it — workers fall
            # back to the empty-cache base.
          end
        end

        rcm.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def view_context_class
            reg = RactorRailsShim._view_context_registry
            v = reg[self] if reg
            return v if v
            if Ractor.main? && instance_variable_defined?(:@view_context_class)
              @view_context_class
            else
              # No registry entry (e.g. a controller loaded after prepare).
              # Fall back to the DetailsKey view_context_class (the empty-cache
              # base) — rendering may fail for controllers needing url_helpers,
              # but simple render :plain works.
              ActionView::LookupContext::DetailsKey.view_context_class
            end
          end
        RUBY
      end
      # uses define_method with blocks → un-shareable Proc from a worker). The
      # built Class is shareable; register it so the fallback builder captures
      # it and workers read it via SHAREABLE_FALLBACK.
      vcc_key = :ractor_rails_shim_lookup_context_view_context_class
      vcc_key_str = vcc_key.inspect
      CLASS_ATTRIBUTES << ["ActionView::LookupContext::DetailsKey", :view_context_class, vcc_key, nil]
      # Build it now in main and stash in IES so the fallback builder picks it up.
      if Ractor.main? && defined?(::ActionView::Base)
        built = ::ActionView::LookupContext::DetailsKey.view_context_class
        # with_empty_template_cache defines compiled_method_container via
        # define_method (block) → un-shareable Proc, callable only from main.
        # Redefine both the instance and singleton versions via string-eval
        # (no captured binding) so they're callable from worker Ractors. The
        # original returns `subclass` (the built class); the instance method
        # returns self.class (== built), the singleton returns self (== built).
        built.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def compiled_method_container; self.class; end
        RUBY
        built.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def compiled_method_container; self; end
        RUBY
        ActiveSupport::IsolatedExecutionState[vcc_key] = built
      end

      # DetailsKey: view_context_class reads the shareable fallback (built in
      # main above). details_keys / digest_cache are per-Ractor caches
      # (workers start empty). The @view_context_mutex is bypassed (no
      # contention in a per-Ractor lazy build, which only happens in main).
      dk = ::ActionView::LookupContext::DetailsKey
      dk_key = :ractor_rails_shim_lookup_context_details_keys
      dc_key = :ractor_rails_shim_lookup_context_digest_cache
      dk_key_str = dk_key.inspect
      dc_key_str = dc_key.inspect
      vcc_key_str2 = vcc_key.inspect
      dk.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def view_context_class
          v = ActiveSupport::IsolatedExecutionState[#{vcc_key_str2}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@view_context_class)
            v = @view_context_class
            ActiveSupport::IsolatedExecutionState[#{vcc_key_str2}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{vcc_key_str2}]
          end
        end
        def details_keys
          v = ActiveSupport::IsolatedExecutionState[#{dk_key_str}]
          return v if v
          if Ractor.main? && instance_variable_defined?(:@details_keys)
            v = @details_keys
          else
            v = Concurrent::Map.new
          end
          ActiveSupport::IsolatedExecutionState[#{dk_key_str}] = v
          v
        end
        def digest_cache(details)
          dc = (ActiveSupport::IsolatedExecutionState[#{dc_key_str}] ||= Concurrent::Map.new)
          dc[details_cache_key(details)] ||= Concurrent::Map.new
        end
        def details_cache_key(details)
          details_keys.fetch(details) do
            if formats = details[:formats]
              unless Template::Types.valid_symbols?(formats)
                details = details.dup
                details[:formats] &= Template::Types.symbols
              end
            end
            details_keys[details] ||= TemplateDetails::Requested.new(**details)
          end
        end
      RUBY
    end

    # Patch I18n::Config's class-variable-backed accessors (default_locale,
    # locale, backend, etc.) to not read @@cvars from a worker Ractor. I18n
    # defines these manually (`@@default_locale ||= :en`), not via
    # cattr_accessor, so the shim's mattr rewrite doesn't catch them. The
    # values are frozen Symbols / shareable config objects; route the
    # frequently-read ones (default_locale, locale) through IES with the same
    # default. Read per-request during view lookup (LookupContext details).
    def _install_i18n_patch
      return if @i18n_patched
      @i18n_patched = true
      _register_patch :i18n, "8.1"
      return unless defined?(::I18n::Config)
      cfg = ::I18n::Config
      dl_key = :ractor_rails_shim_i18n_default_locale
      l_key = :ractor_rails_shim_i18n_locale
      dl_key_str = dl_key.inspect
      l_key_str = l_key.inspect
      cfg.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_locale
          v = ActiveSupport::IsolatedExecutionState[#{dl_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@default_locale)
            cv = class_variable_get(:@@default_locale)
            ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = cv
            return cv
          end
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = :en
          :en
        end
        def default_locale=(locale)
          v = locale && locale.to_sym
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = v
          class_variable_set(:@@default_locale, v) if Ractor.main?
          v
        end
        def locale
          v = ActiveSupport::IsolatedExecutionState[#{l_key_str}]
          return v unless v.nil?
          default_locale
        end
        def locale=(locale)
          v = locale && locale.to_sym
          ActiveSupport::IsolatedExecutionState[#{l_key_str}] = v
          v
        end
      RUBY

      # Patch I18n.fallbacks (a singleton method on the I18n module) to not
      # read the @@fallbacks class variable from a worker Ractor. It already
      # uses Fiber/Thread-local storage with @@fallbacks as the fallback;
      # route the @@fallbacks read through IES so workers build their own
      # I18n::Locale::Fallbacks. Called per-request via LookupContext details.
      if defined?(::I18n)
        i18n = ::I18n
        fb_key = :ractor_rails_shim_i18n_fallbacks
        fb_key_str = fb_key.inspect
        i18n.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def fallbacks
            v = ActiveSupport::IsolatedExecutionState[#{fb_key_str}]
            return v unless v.nil?
            if Ractor.main? && class_variable_defined?(:@@fallbacks)
              cv = class_variable_get(:@@fallbacks)
              if cv
                ActiveSupport::IsolatedExecutionState[#{fb_key_str}] = cv
                return cv
              end
            end
            built = I18n::Locale::Fallbacks.new
            ActiveSupport::IsolatedExecutionState[#{fb_key_str}] = built
            built
          end
        RUBY

        # I18n::Locale::Tag.implementation — manual @@implementation ||= Simple.
        # The value is a module (shareable). Route through IES.
        if defined?(::I18n::Locale::Tag)
          tag = ::I18n::Locale::Tag
          tag_key = :ractor_rails_shim_i18n_tag_implementation
          tag_key_str = tag_key.inspect
          tag.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def implementation
              v = ActiveSupport::IsolatedExecutionState[#{tag_key_str}]
              return v unless v.nil?
              if Ractor.main? && class_variable_defined?(:@@implementation)
                cv = class_variable_get(:@@implementation)
                ActiveSupport::IsolatedExecutionState[#{tag_key_str}] = cv
                return cv
              end
              ActiveSupport::IsolatedExecutionState[#{tag_key_str}] = I18n::Locale::Tag::Simple
              I18n::Locale::Tag::Simple
            end
          RUBY
        end
      end
    end

    # Patch ActionView::Template::Handlers class-var accessors
    # (@@template_handlers, @@template_extensions, @@default_template_handlers)
    # to not read @@cvars from a worker Ractor. The values are Hashes/Arrays of
    # Symbols + handler objects; route the read paths through IES. The handlers
    # Hash is registered at boot (frozen shared app → read-only). Workers read
    # the shareable fallback. `extensions` is called per-request via
    # LookupContext details.
    def _install_template_handlers_patch
      return if @template_handlers_patched
      @template_handlers_patched = true
      _register_patch :template_handlers, "8.1"
      return unless defined?(::ActionView::Template::Handlers)
      h = ::ActionView::Template::Handlers
      th_key = :ractor_rails_shim_av_template_handlers
      ext_key = :ractor_rails_shim_av_template_extensions
      dth_key = :ractor_rails_shim_av_default_template_handlers
      th_key_str = th_key.inspect
      ext_key_str = ext_key.inspect
      dth_key_str = dth_key.inspect
      h.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def template_handlers_hash
          v = ActiveSupport::IsolatedExecutionState[#{th_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@template_handlers)
            cv = class_variable_get(:@@template_handlers)
            ActiveSupport::IsolatedExecutionState[#{th_key_str}] = cv
            cv
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{th_key_str}] || {}
          end
        end
        def extensions
          v = ActiveSupport::IsolatedExecutionState[#{ext_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@template_extensions)
            cv = class_variable_get(:@@template_extensions)
            cv ||= class_variable_get(:@@template_handlers).keys if class_variable_defined?(:@@template_handlers)
            ActiveSupport::IsolatedExecutionState[#{ext_key_str}] = cv
            cv
          else
            template_handlers_hash.keys
          end
        end
        def template_handler_extensions
          template_handlers_hash.keys.map(&:to_s).sort
        end
        def registered_template_handler(extension)
          extension && template_handlers_hash[extension.to_sym]
        end
        def handler_for_extension(extension)
          registered_template_handler(extension) || begin
            v = ActiveSupport::IsolatedExecutionState[#{dth_key_str}]
            if v.nil?
              if Ractor.main? && class_variable_defined?(:@@default_template_handlers)
                v = class_variable_get(:@@default_template_handlers)
                ActiveSupport::IsolatedExecutionState[#{dth_key_str}] = v
              else
                v = RactorRailsShim::SHAREABLE_FALLBACK[#{dth_key_str}]
              end
            end
            v
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionView::Template::Handlers", :template_handlers, th_key, {}]
      CLASS_ATTRIBUTES << ["ActionView::Template::Handlers", :default_template_handlers, dth_key, nil]
    end

    # Patch ActiveSupport::ExecutionContext's raw class ivars
    # (@after_change_callbacks, @nestable) to not read them from a worker
    # Ractor. `after_change` blocks are registered at boot (e.g. by railties to
    # flush CurrentAttributes) and capture self → unshareable. For a read-only
    # shared app, workers get an empty callback list (no flush — workers start
    # with empty per-Ractor CurrentAttributes anyway) and nestable=false.
    # `[]=` and `set` are called per-request via controller instrumentation.
    def _install_execution_context_patch
      return if @exec_context_patched
      @exec_context_patched = true
      _register_patch :execution_context, "8.1"
      return unless defined?(::ActiveSupport::ExecutionContext)
      ec = ::ActiveSupport::ExecutionContext
      acb_key = :ractor_rails_shim_exec_context_after_change_callbacks
      nest_key = :ractor_rails_shim_exec_context_nestable
      acb_key_str = acb_key.inspect
      nest_key_str = nest_key.inspect
      ec.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def after_change_callbacks
          v = ActiveSupport::IsolatedExecutionState[#{acb_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@after_change_callbacks)
            v = @after_change_callbacks
            ActiveSupport::IsolatedExecutionState[#{acb_key_str}] = v
            v
          else
            arr = []
            ActiveSupport::IsolatedExecutionState[#{acb_key_str}] = arr
            arr
          end
        end
        def after_change(&block)
          after_change_callbacks << block
        end
        def nestable
          v = ActiveSupport::IsolatedExecutionState[#{nest_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@nestable)
            v = @nestable
            ActiveSupport::IsolatedExecutionState[#{nest_key_str}] = v
            v
          else
            false
          end
        end
        def nestable=(val)
          ActiveSupport::IsolatedExecutionState[#{nest_key_str}] = val
          @nestable = val if Ractor.main?
          val
        end
      RUBY
      # Rewrite the methods that read @after_change_callbacks directly.
      ec.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def set(**options)
          options.symbolize_keys!
          keys = options.keys
          store = record.store
          previous_context = if block_given?
            keys.zip(store.values_at(*keys)).to_h
          end
          store.merge!(options)
          after_change_callbacks.each(&:call)
          if block_given?
            begin
              yield
            ensure
              store.merge!(previous_context)
              after_change_callbacks.each(&:call)
            end
          end
        end
        def []=(key, value)
          record.store[key.to_sym] = value
          after_change_callbacks.each(&:call)
        end
      RUBY
    end

    # Patch ActionDispatch::Request.parameter_parsers (singleton attr_reader
    # backed by @parameter_parsers) to not read the class ivar from a worker
    # Ractor. The value is a Hash of MIME-type → parser (lambdas). Route
    # through IES; workers read the shareable fallback (the boot-time parsers,
    # made shareable). Read per-request during parameter parsing.
    def _install_request_parameter_parsers_patch
      return if @request_param_parsers_patched
      @request_param_parsers_patched = true
      _register_patch :request_parameter_parsers, "8.1"
      return unless defined?(::ActionDispatch::Request)
      req = ::ActionDispatch::Request
      pp_key = :ractor_rails_shim_request_parameter_parsers
      pp_key_str = pp_key.inspect
      req.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def parameter_parsers
          v = ActiveSupport::IsolatedExecutionState[#{pp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@parameter_parsers)
            v = @parameter_parsers
            ActiveSupport::IsolatedExecutionState[#{pp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{pp_key_str}] || ActionDispatch::Request::DEFAULT_PARSERS
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["ActionDispatch::Request", :parameter_parsers, pp_key, nil]
    end

    # Patch Rack::Utils singleton attr_accessors (default_query_parser,
    # multipart_total_part_limit, multipart_file_limit) to not read @ivars
    # from a worker Ractor. The values are shareable once frozen (QueryParser,
    # Integers). Route through IES; workers read the shareable fallback.
    # `default_query_parser` is read per-request during POST parsing.
    def _install_rack_utils_patch
      return if @rack_utils_patched
      @rack_utils_patched = true
      _register_patch :rack_utils, "8.1"
      return unless defined?(::Rack::Utils)
      u = ::Rack::Utils
      dqp_key = :ractor_rails_shim_rack_utils_default_query_parser
      mtp_key = :ractor_rails_shim_rack_utils_multipart_total_part_limit
      mfl_key = :ractor_rails_shim_rack_utils_multipart_file_limit
      dqp_key_str = dqp_key.inspect
      mtp_key_str = mtp_key.inspect
      mfl_key_str = mfl_key.inspect
      u.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_query_parser
          v = ActiveSupport::IsolatedExecutionState[#{dqp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@default_query_parser)
            v = @default_query_parser
            ActiveSupport::IsolatedExecutionState[#{dqp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{dqp_key_str}] || ::Rack::QueryParser::QueryParser.make_default(32)
          end
        end
        def multipart_total_part_limit
          v = ActiveSupport::IsolatedExecutionState[#{mtp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@multipart_total_part_limit)
            v = @multipart_total_part_limit
            ActiveSupport::IsolatedExecutionState[#{mtp_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{mtp_key_str}] || 128
          end
        end
        def multipart_file_limit
          v = ActiveSupport::IsolatedExecutionState[#{mfl_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@multipart_file_limit)
            v = @multipart_file_limit
            ActiveSupport::IsolatedExecutionState[#{mfl_key_str}] = v
            v
          else
            RactorRailsShim::SHAREABLE_FALLBACK[#{mfl_key_str}] || 64
          end
        end
      RUBY
      CLASS_ATTRIBUTES << ["Rack::Utils", :default_query_parser, dqp_key, nil]
      CLASS_ATTRIBUTES << ["Rack::Utils", :multipart_total_part_limit, mtp_key, nil]
      CLASS_ATTRIBUTES << ["Rack::Utils", :multipart_file_limit, mfl_key, nil]
    end

    # Patch Warden::Hooks lazy class-ivar accessors (@_on_request ||= [] etc).
    # Warden middleware holds 6 lazy-init class ivars for callback arrays.
    # make_app_shareable! freezes the middleware instance; the ||= lazy init
    # tries to WRITE on the frozen instance → IsolationError in workers.
    # The callbacks (Procs) were registered at boot and already ran in main;
    # workers treat them as empty (correct for a read-only shared app).
    def _install_warden_hooks_patch
      return if @warden_patched
      @warden_patched = true
      _register_patch :warden_hooks, "8.1"
      return unless defined?(::Warden::Hooks)
      ::Warden::Hooks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _after_set_user
          if Ractor.main? && instance_variable_defined?(:@_after_set_user)
            @_after_set_user
          else
            []
          end
        end
        def _before_failure
          if Ractor.main? && instance_variable_defined?(:@_before_failure)
            @_before_failure
          else
            []
          end
        end
        def _after_failed_fetch
          if Ractor.main? && instance_variable_defined?(:@_after_failed_fetch)
            @_after_failed_fetch
          else
            []
          end
        end
        def _before_logout
          if Ractor.main? && instance_variable_defined?(:@_before_logout)
            @_before_logout
          else
            []
          end
        end
        def _on_request
          if Ractor.main? && instance_variable_defined?(:@_on_request)
            @_on_request
          else
            []
          end
        end
      RUBY
    end

    # Patch ActionDispatch::ExceptionWrapper instance methods that read
    # @@rescue_responses / @@rescue_templates class variables directly
    # (bypassing the mattr_accessor reader the shim already reroutes through
    # IES). Workers can't read class vars; route through the class method.
    def _install_exception_wrapper_patch
      return if @exception_wrapper_patched
      @exception_wrapper_patched = true
      _register_patch :exception_wrapper, "8.1"
      return unless defined?(::ActionDispatch::ExceptionWrapper)
      ::ActionDispatch::ExceptionWrapper.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def rescue_template
          self.class.rescue_templates[exception_class_name]
        end
        def status_code
          ActionDispatch::Response.rack_status_code(self.class.rescue_responses[exception_class_name])
        end
        def rescue_response?
          self.class.rescue_responses.key?(exception.class.name)
        end
      RUBY
    end

    # Patch ActiveSupport::LogSubscriber.logger — a raw class ivar with lazy
    # init (@logger ||= Rails.logger) that's WRITTEN at request teardown via
    # flush_all!. Workers can't write class ivars → IsolationError. Route
    # through IES; workers get Rails.logger (which the shim already routes
    # through IES) so it resolves to the worker's own per-Ractor logger.
    def _install_log_subscriber_patch
      return if @log_subscriber_patched
      @log_subscriber_patched = true
      _register_patch :log_subscriber, "8.1"
      return unless defined?(::ActiveSupport::LogSubscriber)
      ls = ::ActiveSupport::LogSubscriber
      key = :ractor_rails_shim_log_subscriber_logger
      key_str = key.inspect
      ls.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def logger
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@logger)
            @logger
          elsif defined?(::Rails) && ::Rails.respond_to?(:logger)
            ::Rails.logger
          end
        end

        def logger=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
        end
      RUBY
    end

    # The frozen, shareable fallback table for class_attribute / mattr_accessor
    # `prepare_for_ractors!` time from the main ractor's live values, then made
    # shareable. Returns a frozen Hash { ies_key => shareable_value }.
    attr_reader :shareable_fallback

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
      # Pre-compute lazy ivars BEFORE freezing (they mutate the app).
      _precompute_lazy_ivars(app)
      # Neutralize the app's logger IO so Ractor.make_shareable doesn't freeze
      # $stdout/$stderr (freezing STDOUT breaks the process's own output).
      # Workers build their own per-Ractor Rails.logger, so the app-instance
      # logger is unused post-freeze; redirect its logdev to a fresh StringIO
      # sink (which is safely freezable).
      _neutralize_logger_io!(app)
      _replace_unshareable_procs!(app)
      _replace_locks_and_concurrent_maps!(app)
      Ractor.make_shareable(app)
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
         next if o.nil? || seen[o.object_id]
         seen[o.object_id] = true
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

    private

    # Patch the Rails module's class-level accessors (Rails.application,
    # Rails.env, Rails.cache, etc.) to route through IsolatedExecutionState.
    # Defers via a load hook if Rails isn't defined yet (the config/boot.rb case).
    def install_rails_module
      _register_patch :rails_module, "8.1"
      if defined?(::Rails)
        patch_rails_module!(::Rails)
      else
        install_rails_load_hook
      end
    end

    # Defer the Rails-module patch until Rails is defined. A TracePoint on
    # :class fires when `rails.rb` opens `module Rails` (module bodies fire
    # as :class); once the constant is assigned, we patch once and disable
    # the hook.
    def install_rails_load_hook
      return if @rails_load_hook_installed
      @rails_load_hook_installed = true

      @rails_tp = TracePoint.new(:class) do |trace|
        if defined?(::Rails) && !@rails_module_patched
          @rails_tp.disable
          patch_rails_module!(::Rails)
        end
      end
      @rails_tp.enable
    end

    # Rails (and ActiveSupport, and gems) hold constants whose values are
    # mutable Arrays/Hashes/Sets. Reading those constants from a worker Ractor
    # raises Ractor::IsolationError ("can not access non-shareable objects in
    # constant X by non-main ractor"). Unlike class ivars, the value lives in
    # the constant table — the fix is to make it shareable once at boot
    # (deep-freeze + share), which makes the constant readable from every
    # Ractor. Each constant is touched once and only if it currently holds an
    # unshareable value, so this is a no-op once Rails fixes it upstream.
    #
    # The list is a registry of *constant path strings* ("A::B::C"). Callers
    # can add their own via RactorRailsShim.shareable_constants << "MyGem::LIST"
    # before install. Each entry is resolved at install time; missing ones are
    # skipped silently (so the list can name constants that only exist under
    # certain frameworks without conditionally gating each entry).
    SHAREABLE_CONSTANTS = [
      # ActiveSupport
      "ActiveSupport::EnvironmentInquirer::DEFAULT_ENVIRONMENTS",
      "ActiveSupport::EnvironmentInquirer::LOCAL_ENVIRONMENTS",
      "ActiveSupport::ErrorReporter::SEVERITIES",
      "ActiveSupport::CurrentAttributes::INVALID_ATTRIBUTE_NAMES",
      "ActiveSupport::Delegation::RUBY_RESERVED_KEYWORDS",
      # concurrent-ruby
      "Concurrent::NULL",
      # Railties
      "Rails::Railtie::ABSTRACT_RAILTIES",
      "Rails::AppLoader::EXECUTABLES",
      "Rails::Command::HELP_MAPPINGS",
      "Rails::Command::VERSION_MAPPINGS",
      "Rails::Application::INITIAL_VARIABLES",
      # Rack
      "Rack::Utils::PATH_SEPS",
      "Rack::Utils::HTTP_STATUS_CODES",
      "Rack::Utils::COMMON_SEP",
      "Rack::Utils::STATUS_WITH_NO_ENTITY_BODY",
      "Rack::Utils::SYMBOL_TO_STATUS_CODE",
      "Rack::MethodOverride::ALLOWED_METHODS",
      "Rack::MethodOverride::METHOD_OVERRIDES",
      "Rack::Headers::KNOWN_HEADERS",
      "Rack::Request::Helpers::FORM_DATA_MEDIA_TYPES",
      "Rack::Request::Helpers::PARSEABLE_DATA_MEDIA_TYPES",
      "Rack::Request::Helpers::DEFAULT_PORTS",
      "Rack::Mime::MIME_TYPES",
      "Rack::Files::ALLOWED_VERBS",
      "Rack::Files::ALLOW_HEADER",
      "Rack::Response::STATUS_WITH_NO_ENTITY_BODY",
      # ActionDispatch
      "ActionDispatch::FileHandler::PRECOMPRESSED",
      "ActionDispatch::SSL::PERMANENT_REDIRECT_REQUEST_METHODS",
      "ActionDispatch::HostAuthorization::VALID_IP_HOSTNAME",
      "ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT",
      "ActionDispatch::Request::HTTP_METHODS",
      "ActionDispatch::Request::HTTP_METHOD_LOOKUP",
      # ActionView
      "ActionView::LookupContext::Accessors::DEFAULT_PROCS",
      # Mime
      "Mime::SET",
      "Mime::EXTENSION_LOOKUP",
      "Mime::LOOKUP",
      "Mime::Type::TRAILING_STAR_REGEXP",
      "Mime::Type::PARAMETER_SEPARATOR_REGEXP",
      "Mime::Type::ACCEPT_HEADER_REGEXP",
      "Mime::ALL",
      "ActionDispatch::Response::NullContentTypeHeader",
      "ActionDispatch::Response::NO_CONTENT_CODES",
      "ActionDispatch::Response::RackBody::BODY_METHODS",
      "ActionDispatch::Response::Buffer::BODY_METHODS",
      "ActionController::Rendering::RENDER_FORMATS_IN_PRIORITY",
      "ActionController::Base::PROTECTED_IVARS",
      "AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES",
      # ActionDispatch / others are added lazily as they're found; add yours
      # via RactorRailsShim.shareable_constants << "YourGem::CONST"
    ]

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

      # Deep-freeze and reassign. Ractor.make_shareable mutates `val` in
      # place (freezing it and its reachable objects) and returns it.
      shareable = Ractor.make_shareable(val)
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

    # Split "A::B::C" into [A::B (module), :C]. Returns [nil, nil] if the
    # parent isn't defined.
    def split_const_path(path)
      parts = path.split("::")
      return [Object, parts.first.to_sym] if parts.size == 1
      parent = parts[0...-1].inject(Object) { |ns, n| ns.const_get(n) } rescue nil
      return [nil, nil] unless parent
      [parent, parts.last.to_sym]
    end

    # The actual Rails-module patch. Idempotent. Must be called from the
    # main Ractor (it prepends onto Rails.singleton_class).
    def patch_rails_module!(mod)
      return if @rails_module_patched
      @rails_module_patched = true
      do_install_shareable_constants
      _patch_rails_module_body(mod)
    end

    def _patch_rails_module_body(mod)
      k = KEYS

      # Register the Rails module accessors in CLASS_ATTRIBUTES so the
      # shareable-fallback builder captures their main-ractor values at
      # prepare_for_ractors! / make_app_shareable! time and exposes them to
      # worker Ractors (e.g. Rails.logger is read per-request by
      # Rails::Rack::SilenceRequest). `application` is NOT registered — workers
      # get the shared app via Ractor.new(app), not via Rails.application.
      CLASS_ATTRIBUTES << ["Rails", :logger,        k[:logger],        nil]
      CLASS_ATTRIBUTES << ["Rails", :cache,         k[:cache],         nil]
      CLASS_ATTRIBUTES << ["Rails", :backtrace_cleaner, k[:backtrace_cleaner], nil]
      CLASS_ATTRIBUTES << ["Rails", :app_class,     k[:app_class],     nil]

      # We PREPEND a module onto Rails.singleton_class rather than redefine
      # the methods directly, because Rails defines its own `application`,
      # `env`, etc. LATER in rails.rb (`class << self; def application; ...`).
      # A direct module_eval redefinition would be clobbered when Rails'
      # own `def` runs afterward. A prepended module sits in front of the
      # singleton class in the method lookup chain and survives a later
      # `def` on the same class — so our IES-routed reader stays in front.
      # We call `super` to fall back to Rails' original method for the
      # main-ractor lazy-init path (which reads the @application ivar —
      # safe in the main ractor).
      patch = Module.new
      patch.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        # application: IES first; main ractor falls back to Rails' own
        # lazy init via super. Worker ractors return nil (their own IES
        # slot is empty until they boot their own app).
        def application
          v = ActiveSupport::IsolatedExecutionState[#{k[:application].inspect}]
          return v unless v.nil?
          Ractor.main? ? super : nil
        end

        def application=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:application].inspect}] = val
          super if Ractor.main?
          val
        end

        # Simple accessors: app_class, cache, logger, backtrace_cleaner.
        # Workers fall back to the shareable fallback (built from main's
        # value at make_app_shareable! time) when their own IES slot is empty.
        def app_class
          v = ActiveSupport::IsolatedExecutionState[#{k[:app_class].inspect}]
          return v unless v.nil?
          return super if Ractor.main?
          RactorRailsShim::SHAREABLE_FALLBACK[#{k[:app_class].inspect}]
        end
        def app_class=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:app_class].inspect}] = val
          super if Ractor.main?
          val
        end

        def cache
          v = ActiveSupport::IsolatedExecutionState[#{k[:cache].inspect}]
          return v unless v.nil?
          return super if Ractor.main?
          RactorRailsShim::SHAREABLE_FALLBACK[#{k[:cache].inspect}]
        end
        def cache=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:cache].inspect}] = val
          super if Ractor.main?
          val
        end

        def logger
          v = ActiveSupport::IsolatedExecutionState[#{k[:logger].inspect}]
          return v unless v.nil?
          return super if Ractor.main?
          # Loggers are intrinsically mutable (formatters hold tag stacks,
          # logdevs hold IO + Mutex) and can't be shared read-only. Build a
          # per-worker ActiveSupport::BroadcastLogger (which mixes in
          # LoggerSilence#silence, used by Rails::Rack::SilenceRequest)
          # writing to $stderr (each Ractor has its own $stderr stream) and
          # cache it in IES so subsequent reads return the same instance.
          built = ActiveSupport::BroadcastLogger.new(Logger.new($stderr))
          ActiveSupport::IsolatedExecutionState[#{k[:logger].inspect}] = built
          built
        end
        def logger=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:logger].inspect}] = val
          super if Ractor.main?
          val
        end

        def backtrace_cleaner
          v = ActiveSupport::IsolatedExecutionState[#{k[:backtrace_cleaner].inspect}]
          return v unless v.nil?
          return super if Ractor.main?
          RactorRailsShim::SHAREABLE_FALLBACK[#{k[:backtrace_cleaner].inspect}]
        end
        def backtrace_cleaner=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:backtrace_cleaner].inspect}] = val
          super if Ractor.main?
          val
        end

        # env: worker ractors build their own EnvironmentInquirer from ENV
        # (no @ _env ivar to read). Main ractor falls back to super, which
        # lazily builds and caches in @_env.
        def env
          v = ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}]
          return v unless v.nil?
          if Ractor.main?
            super
          else
            built = ActiveSupport::EnvironmentInquirer.new(
              ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence || "development"
            )
            ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}] = built
            built
          end
        end

        def env=(val)
          v = ActiveSupport::EnvironmentInquirer.new(val)
          ActiveSupport::IsolatedExecutionState[#{k[:env].inspect}] = v
          super if Ractor.main?
          v
        end
      RUBY
      mod.singleton_class.prepend(patch)
    end

    # Rewrite Module.mattr_accessor (and friends) so the accessor methods
    # route through IsolatedExecutionState. Uses prepend + module_eval with
    # strings to avoid cross-ractor binding issues.
    def install_mattr_accessor
      _register_patch :mattr_accessor, "8.1"
      return if @mattr_patched
      @mattr_patched = true

      ::Module.prepend(Module.new {
        # The prepended module's body is evaluated in the main ractor at
        # prepend time; the methods it defines are callable from any ractor
        # because they're defined via string eval (no captured binding).
        # But mattr_accessor itself runs at app boot in the main ractor, and
        # the per-accessor redefinition must also use string eval.
        #
        # IMPORTANT: Rails' mattr_accessor/cattr_accessor stores values in
        # CLASS VARIABLES (@@sym), not class instance variables (@sym). The
        # default value is written via class_variable_set("@@sym", default).
        # Class variables are also subject to Ractor::IsolationError from
        # non-main ractors (verified on Ruby 4.0.5), so we route through IES
        # the same way — but the main-ractor fallback must read @@sym, and
        # the seed must run in the main ractor at define-time (via super).
        def mattr_accessor(*syms, instance_reader: true, instance_writer: true,
                           instance_accessor: true, default: nil, **kwargs, &block)
          shareable = kwargs[:shareable]
          mod_name = name

          # Compute the default value the same way Rails does, so we can
          # seed worker-ractor IES slots with it (workers can't read @@sym).
          # The block form is evaluated once here (in main ractor) like Rails.
          sym_default = block_given? && default.nil? ? yield : default

          super # define the methods via the original path (sets @@sym)

          syms.each do |sym|
            key = :"ractor_rails_shim_mattr_#{mod_name}_#{sym}"
            key_str = key.inspect
            cv = "@@#{sym}"
            cv_str = cv.inspect

            # Register so _build_shareable_fallback! can capture the main-ractor
            # value (read from @@sym) at prepare_for_ractors! time. The label
            # is just for diagnostics. The default is stored too so the
            # fallback builder can use it when the live value can't be shared.
            RactorRailsShim::CLASS_ATTRIBUTES << [mod_name, sym, key, sym_default]
            # Store the default in a runtime registry (NOT inlined into the
            # eval'd method body — arbitrary objects like Logger have invalid
            # `.inspect` output). The reader looks it up by key.
            RactorRailsShim::MATTR_DEFAULTS[key] = sym_default
            # If the default is shareable, add to the shareable subset. We
            # rebuild the constant as a new frozen shareable Hash each time
            # (so workers can read the constant even before prepare_for_ractors!
            # runs — e.g. unit tests). const_set warns "already initialized
            # constant"; silence it.
            if sym_default && Ractor.shareable?(sym_default)
              h = RactorRailsShim::SHAREABLE_MATTR_DEFAULTS.dup
              h[key] = sym_default
              h.freeze
              Ractor.make_shareable(h)
              verbose, $VERBOSE = $VERBOSE, nil
              begin
                RactorRailsShim.const_set(:SHAREABLE_MATTR_DEFAULTS, h)
              ensure
                $VERBOSE = verbose
              end
            end

            # Redefine the class reader via string eval (no captured binding).
            # Class variables are only touched from the main ractor; worker
            # ractors fall back to SHAREABLE_FALLBACK (built from main's @@sym
            # at prepare_for_ractors! time) when their own IES slot is empty.
            # NOTE: we deliberately do NOT inline the default value here —
            # arbitrary objects (e.g. Logger) have invalid `.inspect` output.
            # The fallback builder captures the live value (which may equal
            # the default) at prepare time.
            singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{sym}
                v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                return v unless v.nil?

                if #{!!shareable}
                  if class_variable_defined?(#{cv_str})
                    class_variable_get(#{cv_str})
                  end
                elsif Ractor.main?
                  if class_variable_defined?(#{cv_str})
                    class_variable_get(#{cv_str})
                  else
                    nil
                  end
                else
                  # Worker: try the shareable fallback (built from main's @@sym
                  # at prepare_for_ractors! time). If empty, try the
                  # definition-time default (only the shareable subset — the
                  # full MATTR_DEFAULTS holds unshareable defaults like Logger
                  # which workers can't read via the constant).
                  fb = RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
                  return fb unless fb.nil?
                  RactorRailsShim::SHAREABLE_MATTR_DEFAULTS[#{key_str}]
                end
              end

              def #{sym}=(val)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                if Ractor.main?
                  class_variable_set(#{cv_str}, val) if class_variable_defined?(#{cv_str})
                  class_variable_set(#{cv_str}, val) unless class_variable_defined?(#{cv_str})
                end
                val
              end
            RUBY

            # Instance readers/writers route through IES directly (NOT
            # self.class.#{sym}). Rails' original uses @@sym (a class variable
            # inherited by including classes); the shim routes through IES,
            # so the instance reader must also use IES. Using self.class.sym
            # would fail for mattr_accessor on Modules (e.g.
            # ActionView::Helpers::FormHelper#form_with_generates_ids):
            # self.class is the including class (ActionView::Base), which
            # doesn't have the module's singleton method.
            # Only redefine if instance_accessor is on (matches Rails).
            if instance_reader && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}
                  v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                  return v unless v.nil?
                  if Ractor.main?
                    self.class.class_variable_defined?(#{cv_str}) ? self.class.class_variable_get(#{cv_str}) : nil
                  else
                    RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
                  end
                end
              RUBY
            end
            if instance_writer && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}=(val)
                  ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                  self.class.class_variable_set(#{cv_str}, val) if Ractor.main? && self.class.class_variable_defined?(#{cv_str})
                  val
                end
              RUBY
            end
          end
        end

        # cattr_accessor is an alias for mattr_accessor in Rails; route it too.
        if method_defined?(:cattr_accessor, true)
          alias_method :_unshimmed_cattr_accessor, :cattr_accessor
          def cattr_accessor(*args, **kwargs, &block)
            mattr_accessor(*args, **kwargs, &block)
          end
        end
      })
    end

    # Rewrite ActiveSupport::ClassAttribute (used by `class_attribute`) so the
    # reader/writer methods are defined via string eval instead of
    # `define_method` with blocks. Blocks capture the defining Ractor's
    # binding; calling them from a worker Ractor raises
    # "defined with an un-shareable Proc in a different Ractor".
    # `class_attribute` is used for Rails::Application#executor, #reloader,
    # ActiveSupport::Reloader#executor/#check, and many framework globals —
    # all read/written during app boot, which now runs in worker Ractors.
    #
    # Strategy: route the per-attribute storage (`__class_attr_<name>`) through
    # IsolatedExecutionState, mirroring the mattr_accessor rewrite. Defaults
    # are seeded once in the main Ractor at class_attribute-definition time
    # (the original semantics). Worker Ractors get nil from the reader until
    # they set their own value via the writer (which always works — the writer
    # is string-eval'd, no captured binding). In practice workers boot their
    # own app instance and the finisher sets executor/check/etc. during
    # initialize!, so the default is only read as a fallback.
    def install_class_attribute
      _register_patch :class_attribute, "8.1"
      return if @class_attr_patched
      @class_attr_patched = true
      if defined?(::ActiveSupport::ClassAttribute)
        patch_class_attribute!
      else
        # Defer until ActiveSupport::ClassAttribute loads. A TracePoint(:class)
        # fires when `module ClassAttribute` opens. One-shot.
        @ca_tp = TracePoint.new(:class) do |trace|
          if defined?(::ActiveSupport::ClassAttribute) && !@ca_patched
            @ca_tp.disable
            patch_class_attribute!
          end
        end
        @ca_tp.enable
      end
    end

    # The actual patch. Idempotent. Must run in the main Ractor.
    # `redefine` is a singleton method on ClassAttribute (defined in
    # `class << self`), so we prepend onto the singleton class.
    def patch_class_attribute!
      return if @ca_patched
      @ca_patched = true
      ::ActiveSupport::ClassAttribute.singleton_class.prepend(Module.new {
        # redefine is called once per attribute at class_attribute-definition
        # time (in the main Ractor). The original defines methods with blocks;
        # we replace with string-eval'd methods that route through IES so
        # they're callable from any Ractor. The default value is seeded into
        # the main Ractor's IES slot immediately (matching original semantics
        # where the reader returns the default until a subclass overrides).
        def redefine(owner, name, namespaced_name, value)
          key = :"ractor_rails_shim_class_attr_#{owner.object_id}_#{namespaced_name}"
          key_str = key.inspect

          # Seed the main Ractor's IES slot with the default. Only seed in
          # main — workers start nil and set their own value via the writer.
          ActiveSupport::IsolatedExecutionState[key] = value if Ractor.main?

          # Also store in CLASS_ATTR_VALUES so the reader can fall back to it
          # in the MAIN ractor on non-boot threads. IES is thread-local: Puma's
          # request threads have empty IES slots, so the reader returns nil
          # without this fallback. This is the bug that breaks normal (non-
          # Ractor) multi-threaded servers — the minimal --minimal app didn't
          # hit it because /up doesn't trigger LogSubscriber.log_levels.
          # CLASS_ATTR_VALUES is NOT shareable (values may be mutable); only
          # safe to read from the main ractor.
          RactorRailsShim::CLASS_ATTR_VALUES[key] = value

          # Register so _build_shareable_fallback! can capture + make shareable
          # at prepare_for_ractors! time. owner.name may be nil for anonymous
          # classes (e.g. spec fixtures); use a stable label in that case.
          # The default value is stored too so the fallback builder can use it
          # when the live value can't be made shareable (e.g. __callbacks holds
          # self-capturing Procs — workers get the empty default, treating
          # boot-time callbacks as already-run, which is correct for a frozen
          # shared app).
          owner_label = owner.respond_to?(:name) ? owner.name : owner.class.name
          owner_label = owner_label || "anon_#{owner.class.name}_#{owner.object_id}"
          RactorRailsShim::CLASS_ATTRIBUTES << [owner_label, namespaced_name, key, value]

          # Always define the namespaced reader/writer on owner's singleton
          # class via string eval (no captured binding). The class_attribute
          # macro itself also defines `def #{name}; #{namespaced_name}; end`
          # via class_eval (string-eval'd, safe) on the owner — that calls our
          # IES-routed namespaced reader/writer. We override BOTH the namespaced
          # and (when owner is a module's singleton) the public name.
          #
          # Worker-Ractor fallback: when the worker's own IES slot is empty
          # (which it is by default — the value lives in main's slot), fall
          # back to the frozen shareable table built at prepare_for_ractors!
          # time. This is read-only and shared across all workers; workers that
          # need their own mutable value call the writer, which writes their
          # IES slot and shadows the fallback.
          target = owner.singleton_class? ? owner : owner.singleton_class
          target.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{namespaced_name}
              v = ActiveSupport::IsolatedExecutionState[#{key_str}]
              return v unless v.nil?
              fb = RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
              return fb unless fb.nil?
              RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] if Ractor.main?
            end

            def #{namespaced_name}=(new_value)
              ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
              RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] = new_value if Ractor.main?
              new_value
            end
          RUBY

          # When owner is a module's singleton class, the original also
          # defines a public reader `def #{name} { value }` on owner directly
          # (block-based). Override it with the IES-routed version + fallback.
          if owner.singleton_class? && owner.attached_object.is_a?(Module)
            owner.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{name}
                v = ActiveSupport::IsolatedExecutionState[#{key_str}]
                return v unless v.nil?
                fb = RactorRailsShim::SHAREABLE_FALLBACK[#{key_str}]
                return fb unless fb.nil?
                RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] if Ractor.main?
              end

              def #{name}=(new_value)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
                RactorRailsShim::CLASS_ATTR_VALUES[#{key_str}] = new_value if Ractor.main?
                new_value
              end
            RUBY
          end
        end

        # redefine_method is used by `redefine` internally and by other call
        # sites (rare). The class_attribute path goes through our `redefine`
        # above; keep the original block-based behavior for any other callers
        # so we don't break unrelated code.
        def redefine_method(owner, name, private: false, &block)
          super
        end
      })
    end

    # Patch Zeitwerk::Registry to route its class ivars (@loaders, @mutex,
    # @gem_loaders_by_root_file, @autoloads, @explicit_namespaces, @inceptions)
    # through IsolatedExecutionState. Zeitwerk uses raw class ivars (not
    # mattr_accessor), so the shim's macro rewrite doesn't catch them. Each
    # Ractor that boots a Rails app gets its own registry state (its own
    # loaders list, its own mutex, its own autoloads map), which is correct
    # for per-Ractor boot: each worker's autoloaders are independent.
    #
    # The defaults are the same classes Zeitwerk instantiates at module-load
    # time (Loaders, Hash, Autoloads, ExplicitNamespaces, Inceptions, Mutex).
    # Workers lazily build their own on first read.
    def install_zeitwerk_registry
      return if @zeitwerk_patched
      @zeitwerk_patched = true
      _register_patch :zeitwerk_registry, "8.1"
      if defined?(::Zeitwerk::Registry)
        patch_zeitwerk_registry!
      else
        # Defer until Zeitwerk loads. A TracePoint(:class) fires when
        # `module Registry` opens. One-shot.
        @zw_tp = TracePoint.new(:class) do |trace|
          if defined?(::Zeitwerk::Registry) && !@zeitwerk_registry_patched
            @zw_tp.disable
            patch_zeitwerk_registry!
          end
        end
        @zw_tp.enable
      end
    end

    def patch_zeitwerk_registry!
      return if @zeitwerk_registry_patched
      @zeitwerk_registry_patched = true

      reg = ::Zeitwerk::Registry
      # The ivars Zeitwerk sets at the bottom of registry.rb. Map each to an
      # IES key and a default-builder string (eval'd in the reader when the
      # Ractor's slot is empty). Builders reference Zeitwerk constants by
      # full path so they're resolvable from any Ractor.
      ivars = {
        loaders:                  [:ractor_rails_shim_zw_loaders,    "Zeitwerk::Registry::Loaders.new"],
        gem_loaders_by_root_file: [:ractor_rails_shim_zw_gem,        "{}"],
        autoloads:                [:ractor_rails_shim_zw_autoloads,  "Zeitwerk::Registry::Autoloads.new"],
        explicit_namespaces:      [:ractor_rails_shim_zw_explicit,   "Zeitwerk::Registry::ExplicitNamespaces.new"],
        inceptions:               [:ractor_rails_shim_zw_inceptions, "Zeitwerk::Registry::Inceptions.new"],
        mutex:                    [:ractor_rails_shim_zw_mutex,      "Mutex.new"],
      }

      # Redefine each reader (and the mutex, which is read directly as @mutex)
      # to route through IES with lazy per-Ractor init. Use a PREPENDED module
      # (not direct module_eval on the singleton class) because Zeitwerk's
      # `attr_reader :loaders` etc. run LATER in the module body and would
      # clobber a direct redefinition — same load-order issue as the Rails
      # module accessors. A prepended module stays in front of the lookup chain.
      #
      # In the MAIN ractor, fall back to the existing ivar (set by Zeitwerk at
      # the bottom of registry.rb) so main-ractor state is preserved. Worker
      # ractors lazily build their own via the builder string.
      reader_patch = Module.new
      ivars.each do |ivar, (key, builder)|
        key_str = key.inspect
        ivar_sym = :"@#{ivar}"
        ivar_str = ivar_sym.inspect
        reader_patch.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{ivar}
            v = ActiveSupport::IsolatedExecutionState[#{key_str}]
            return v unless v.nil?
            if Ractor.main?
              existing = instance_variable_get(#{ivar_str}) if instance_variable_defined?(#{ivar_str})
              if existing
                ActiveSupport::IsolatedExecutionState[#{key_str}] = existing
                return existing
              end
            end
            v = #{builder}
            ActiveSupport::IsolatedExecutionState[#{key_str}] = v
            v
          end
        RUBY
      end
      reg.singleton_class.prepend(reader_patch)

      # `conflicting_root_dir?` and `loader_for_gem` read @mutex / @gem_loaders
      # directly via instance_variable_get-ish access (they use @mutex in the
      # method body). Since we redefined the readers, the direct @mutex refs
      # in those methods still hit the ivar. We need to rewrite those two
      # methods to call the reader instead. Easiest: prepend a module that
      # calls self.mutex / self.gem_loaders_by_root_file.
      reg.singleton_class.prepend(Module.new {
        def conflicting_root_dir?(loader, new_root_dir)
          mutex.synchronize do
            loaders.each do |existing_loader|
              next if existing_loader == loader
              existing_loader.__roots.each_key do |existing_root_dir|
                next if !new_root_dir.start_with?(existing_root_dir) && !existing_root_dir.start_with?(new_root_dir)
                new_root_dir_slash = new_root_dir + '/'
                existing_root_dir_slash = existing_root_dir + '/'
                next if !new_root_dir_slash.start_with?(existing_root_dir_slash) && !existing_root_dir_slash.start_with?(new_root_dir_slash)
                next if loader.__ignores?(existing_root_dir)
                break if existing_loader.__ignores?(new_root_dir)
                return existing_loader
              end
            end
            nil
          end
        end

        def loader_for_gem(root_file, namespace:, warn_on_extra_files:)
          h = gem_loaders_by_root_file
          h[root_file] ||= Zeitwerk::GemLoader.__new(root_file, namespace: namespace, warn_on_extra_files: warn_on_extra_files)
        end

        def unregister_loader(loader)
          gem_loaders_by_root_file.delete_if { |_, l| l == loader }
        end
      })
    end

    # Patch ActiveSupport::ExecutionWrapper.active_key to not write a class
    # ivar from a worker Ractor. The original is `@active_key ||= :"..."`,
    # a raw class-ivar write — illegal from non-main Ractors. The value is a
    # frozen Symbol (pure function of object_id), so we route the cache
    # through IES (per-Ractor; each Ractor computes the same Symbol from the
    # same object_id, so the cached value is identical across Ractors).
    # ExecutionWrapper is the base for Reloader/Executor; `active_key` is
    # called on every request via ActionDispatch::Executor middleware.
    def install_execution_wrapper
      return if @exec_wrapper_patched
      @exec_wrapper_patched = true
      _register_patch :execution_wrapper, "8.1"
      if defined?(::ActiveSupport::ExecutionWrapper)
        patch_execution_wrapper!
      else
        @ew_tp = TracePoint.new(:class) do |trace|
          if defined?(::ActiveSupport::ExecutionWrapper) && !@exec_wrapper_registry_patched
            @ew_tp.disable
            patch_execution_wrapper!
          end
        end
        @ew_tp.enable
      end
    end

    def patch_execution_wrapper!
      return if @exec_wrapper_registry_patched
      @exec_wrapper_registry_patched = true
      ew = ::ActiveSupport::ExecutionWrapper
      key = :ractor_rails_shim_exec_wrapper_active_key
      key_str = key.inspect
      # active_key returns :"active_execution_wrapper_<object_id>"; a frozen
      # Symbol is shareable. Compute it once per Ractor and cache in IES.
      ew.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def active_key
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          sym = :"active_execution_wrapper_\#{object_id}"
          ActiveSupport::IsolatedExecutionState[#{key_str}] = sym
          sym
        end
      RUBY

      # Patch ActiveSupport::Callbacks#run_callbacks to tolerate a nil
      # __callbacks (the case in worker Ractors whose class_attribute fallback
      # couldn't be made shareable because callback chains hold frozen,
      # self-capturing Procs). For a frozen, read-only shared app the boot-time
      # callbacks (ExecutionContext push/pop, CurrentAttributes clear) already
      # ran in the main Ractor at boot; worker Ractors don't need to re-run
      # them per request (CurrentAttributes/ExecutionContext are thread-local,
      # hence per-Ractor, and start empty in a fresh worker). When __callbacks
      # is nil, run_callbacks just yields the block — matching the empty-chain
      # fast path in the original.
      if defined?(::ActiveSupport::Callbacks)
        ::ActiveSupport::Callbacks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def run_callbacks_with_nil_safe(kind, type = nil)
            callbacks = __callbacks[kind.to_sym] if __callbacks
            if callbacks.nil? || callbacks.empty?
              yield if block_given?
            else
              run_callbacks_without_nil_safe(kind, type) { yield if block_given? }
            end
          end
          alias_method :run_callbacks_without_nil_safe, :run_callbacks
          alias_method :run_callbacks, :run_callbacks_with_nil_safe
        RUBY
      end

      # Patch ActiveSupport::Notifications.notifier to not read the @notifier
      # class ivar from a worker Ractor. The original is `attr_accessor
      # :notifier` with `@notifier = Fanout.new` set at module load — a raw
      # class ivar holding a Fanout (which has a Mutex + subscriber Procs,
      # both unshareable). Workers get their own per-Ractor Fanout (no
      # subscribers — instrumentation is a no-op in workers, which is correct
      # for a read-only shared app where log subscribers already ran in main).
      # `notifier` is read by `instrumenter` (per-request via Rails::Rack::Logger).
      if defined?(::ActiveSupport::Notifications)
        notif = ::ActiveSupport::Notifications
        nkey = :ractor_rails_shim_notifications_notifier
        nkey_str = nkey.inspect
        notif.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def notifier
            v = ActiveSupport::IsolatedExecutionState[#{nkey_str}]
            return v unless v.nil?
            if Ractor.main? && instance_variable_defined?(:@notifier)
              @notifier
            else
              built = ActiveSupport::Notifications::Fanout.new
              ActiveSupport::IsolatedExecutionState[#{nkey_str}] = built
              built
            end
          end
        RUBY
      end
    end

    # --- make_app_shareable! helpers ---

    # Callable replacements (defined via string eval — no captured binding,
    # so they're callable from any Ractor once frozen).
    # A NoOpProc replaces boot-time procs (initializer blocks, Concern
    # included blocks, deprecation behaviors) that are never called post-boot.
    # A Callable holds a target + method name and forwards `call`.
    # A CallableConst holds a frozen value and returns it.
    # A RequestCallable calls a method on its request arg.
    module_eval <<-RUBY, __FILE__, __LINE__ + 1
      class NoOpProc
        def call(*_); nil; end
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
        def call(request); request.__send__(@method_name); end
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
        next if o.nil?
        if o.is_a?(Proc)
          procs << [o, _path, parent, ivar]
          next
        end
        next if seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
        o.instance_variables.each do |iv|
          begin; v = o.instance_variable_get(iv); rescue; next; end
          stack << [v, "#{_path}.#{iv}", o, iv] if v
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
          files_server = _find_files_server(mw) || parent
          Callable.new(files_server, :get)
        elsif src.end_with?(COOKIE_LOC)
          RequestCallable.new(:cookies_same_site_protection)
        else
          NoOpProc.new
        end

      if ivar == :__default_proc__
        parent.default = nil
      elsif ivar
        parent.instance_variable_set(ivar, replacement) rescue nil
      elsif parent.is_a?(Array)
        idx = parent.index(proc_obj)
        if idx then parent[idx] = replacement
        else parent.each_with_index { |e, i| parent[i] = replacement if e.equal?(proc_obj) }
        end
      elsif parent.is_a?(Hash)
        key = parent.key(proc_obj)
        parent[key] = replacement if key
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
        next if o.nil? || seen[o.object_id]
        seen[o.object_id] = true
        next if o.is_a?(Mutex) || o.is_a?(Monitor)
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
        if o.is_a?(Array); o.each_with_index { |e, i| stack << [e, "#{_p}[#{i}]", o, nil] if e }
        elsif o.is_a?(Hash); o.each { |k, val| stack << [k, "#{_p}.key", o, nil] if k; stack << [val, "#{_p}[#{k.inspect}]", o, nil] if val }
        end
      end
    end
  end
end