# frozen_string_literal: true

# Patch the Rails module's class-level accessors (Rails.application,
# Rails.env, Rails.cache, etc.) to route through IsolatedExecutionState.
# The generic constant-sharing utilities (make_constant_shareable,
# split_const_path, do_install_shareable_constants, install_shareable_constants,
# shareable_constants) now live in core.rb (alongside SHAREABLE_CONSTANTS).

module RactorRailsShim
  class << self
    # Railties constants (the rest are in their per-concern files: rack.rb,
    # action_view.rb, action_controller.rb, action_dispatch.rb,
    # active_support.rb, warden.rb). Each file concats into
    # RactorRailsShim::SHAREABLE_CONSTANTS (defined empty in core.rb).
    SHAREABLE_CONSTANTS.concat([
      "Rails::Railtie::ABSTRACT_RAILTIES",
      "Rails::AppLoader::EXECUTABLES",
      "Rails::Command::HELP_MAPPINGS",
      "Rails::Command::VERSION_MAPPINGS",
      "Rails::Application::INITIAL_VARIABLES",
    ])

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
          if Ractor.main?
            super
          else
            RactorRailsShim.const_defined?(:SHAREABLE_APP) ? RactorRailsShim::SHAREABLE_APP : nil
          end
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
