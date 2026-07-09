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

  class << self
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
      install_mattr_accessor
      install_class_attribute
      install_zeitwerk_registry
      install_rails_module
      install_shareable_constants
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
    def prepare_for_ractors!
      do_install_shareable_constants
    end

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
      prepare_for_ractors! unless @shareable_constants_done
      _precompute_lazy_ivars(app)
      _replace_unshareable_procs!(app)
      _replace_locks_and_concurrent_maps!(app)
      Ractor.make_shareable(app)
      app
    end

    private

    # Patch the Rails module's class-level accessors (Rails.application,
    # Rails.env, Rails.cache, etc.) to route through IsolatedExecutionState.
    # Defers via a load hook if Rails isn't defined yet (the config/boot.rb case).
    def install_rails_module
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
      "Rack::Mime::MIME_TYPES",
      "Rack::Files::ALLOWED_VERBS",
      "Rack::Files::ALLOW_HEADER",
      "Rack::Response::STATUS_WITH_NO_ENTITY_BODY",
      # ActionDispatch
      "ActionDispatch::FileHandler::PRECOMPRESSED",
      "ActionDispatch::SSL::PERMANENT_REDIRECT_REQUEST_METHODS",
      "ActionDispatch::HostAuthorization::VALID_IP_HOSTNAME",
      "ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT",
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
        def app_class
          v = ActiveSupport::IsolatedExecutionState[#{k[:app_class].inspect}]
          return v unless v.nil?
          Ractor.main? ? super : nil
        end
        def app_class=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:app_class].inspect}] = val
          super if Ractor.main?
          val
        end

        def cache
          v = ActiveSupport::IsolatedExecutionState[#{k[:cache].inspect}]
          return v unless v.nil?
          Ractor.main? ? super : nil
        end
        def cache=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:cache].inspect}] = val
          super if Ractor.main?
          val
        end

        def logger
          v = ActiveSupport::IsolatedExecutionState[#{k[:logger].inspect}]
          return v unless v.nil?
          Ractor.main? ? super : nil
        end
        def logger=(val)
          ActiveSupport::IsolatedExecutionState[#{k[:logger].inspect}] = val
          super if Ractor.main?
          val
        end

        def backtrace_cleaner
          v = ActiveSupport::IsolatedExecutionState[#{k[:backtrace_cleaner].inspect}]
          return v unless v.nil?
          Ractor.main? ? super : nil
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
            has_default = !sym_default.nil?
            default_val = has_default ? sym_default.inspect : "nil"

            # Redefine the class reader via string eval (no captured binding).
            # Class variables are only touched from the main ractor; worker
            # ractors seed their IES slot from the captured default value.
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
                  val = #{has_default ? default_val : 'nil'}
                  ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                  val
                end
              end

              def #{sym}=(val)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = val
                if Ractor.main? && class_variable_defined?(#{cv_str})
                  class_variable_set(#{cv_str}, val)
                elsif Ractor.main?
                  class_variable_set(#{cv_str}, val)
                end
                val
              end
            RUBY

            # Instance readers/writers route through the class methods.
            # Only redefine if instance_accessor is on (matches Rails).
            if instance_reader && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}; self.class.#{sym}; end
              RUBY
            end
            if instance_writer && instance_accessor
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{sym}=(val); self.class.#{sym} = val; end
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

          # Always define the namespaced reader/writer on owner's singleton
          # class via string eval (no captured binding). The class_attribute
          # macro itself also defines `def #{name}; #{namespaced_name}; end`
          # via class_eval (string-eval'd, safe) on the owner — that calls our
          # IES-routed namespaced reader/writer. We override BOTH the namespaced
          # and (when owner is a module's singleton) the public name.
          target = owner.singleton_class? ? owner : owner.singleton_class
          target.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{namespaced_name}
              ActiveSupport::IsolatedExecutionState[#{key_str}]
            end

            def #{namespaced_name}=(new_value)
              ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
              new_value
            end
          RUBY

          # When owner is a module's singleton class, the original also
          # defines a public reader `def #{name} { value }` on owner directly
          # (block-based). Override it with the IES-routed version.
          if owner.singleton_class? && owner.attached_object.is_a?(Module)
            owner.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{name}
                ActiveSupport::IsolatedExecutionState[#{key_str}]
              end

              def #{name}=(new_value)
                ActiveSupport::IsolatedExecutionState[#{key_str}] = new_value
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
      mw = app.instance_variable_get(:@app)
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