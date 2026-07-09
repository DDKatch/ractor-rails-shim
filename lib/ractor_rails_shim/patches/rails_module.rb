# frozen_string_literal: true

# Patch the Rails module's class-level accessors (Rails.application,
# Rails.env, Rails.cache, etc.) to route through IsolatedExecutionState.
# Also: SHAREABLE_CONSTANTS registry + make_constant_shareable.

module RactorRailsShim
  class << self
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
      # Devise
      "Devise::ParameterSanitizer::DEFAULT_PERMITTED_ATTRIBUTES",
      "Devise::Mapping::DEFAULTS",
      "Devise::DEVS",
      "Devise::URLS",
      "Devise::STRATEGIES",
      "Devise::CONTROLLERS",
      "Devise::MODULES",
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
  end
end
