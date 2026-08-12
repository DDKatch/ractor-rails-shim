# frozen_string_literal: true

# Patches for AbstractController: controller_path, action_methods,
# abstract?, _prefixes, and ParameterEncoding.
# Each uses per-Ractor IES caches and guards Ractor.main? before reading
# class ivars.

module RactorRailsShim
  # ActionController / AbstractController constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActionController::Rendering::RENDER_FORMATS_IN_PRIORITY",
    "ActionController::Base::PROTECTED_IVARS",
    "AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES",
    # Strong-parameters scalar allow-list, read by permitted_scalar? on every
    # permit/require. An Array of classes -> not shareable by default.
    "ActionController::Parameters::PERMITTED_SCALAR_TYPES",
  ])

  # Captured at prepare_for_ractors! time: the main Ractor's resolved
  # ActionController forgery-protection flag. Replayed in worker Ractors (see
  # _install_action_controller_forgery_patch) because `allow_forgery_protection`
  # delegates to `config.allow_forgery_protection`, and a worker's shared
  # `config` resolves to an EMPTY OrderedOptions -> the flag is lost, so no CSRF
  # token is ever emitted in workers (forms render without an authenticity
  # token, and POST/CSRF validation can't be exercised). A boolean is shareable.
  SHAREABLE_ALLOW_FORGERY = false

  class << self
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
            RactorRailsShim.storage[:ractor_rails_shim_param_encodings]
          end
          if enc && enc.has_key?(action.to_s)
            enc[action.to_s]
          end
        end
      RUBY
    end

    # Replay ActionController's forgery-protection flag in worker Ractors.
    # `allow_forgery_protection` delegates to `config.allow_forgery_protection`;
    # in a worker the shared `config` is an empty ActiveSupport::OrderedOptions,
    # so forms never render a CSRF token (breaking token issuance/validation in
    # workers). Capture the resolved flag from the main Ractor at prepare time
    # (after any boot-time override) and force it in workers so token
    # issuance/validation work off the frozen, shared graph.
    def _install_action_controller_forgery_patch
      return if @action_controller_forgery_patched
      @action_controller_forgery_patched = true
      _register_patch :action_controller_forgery, "8.1"
      return unless defined?(::ActionController::RequestForgeryProtection)
      return unless defined?(::ActionController::Base)

      # Capture the resolved flag. ActionController::Base.allow_forgery_protection
      # is a class method that reads config; in the main Ractor config carries
      # the boot-time override. Booleans are shareable.
      _reassign_shareable_const(
        :SHAREABLE_ALLOW_FORGERY,
        !!::ActionController::Base.allow_forgery_protection
      )

      mod = ::ActionController::Base
      # Override the instance-method delegation (used by protect_against_forgery?).
      mod.module_eval do
        def allow_forgery_protection
          ::Ractor.main? ? super : ::RactorRailsShim::SHAREABLE_ALLOW_FORGERY
        end
      end
      # Override the class-method delegation (singleton delegate to :config).
      mod.singleton_class.module_eval do
        def allow_forgery_protection
          ::Ractor.main? ? super : ::RactorRailsShim::SHAREABLE_ALLOW_FORGERY
        end
      end
    end

    # Patch AbstractController::Base.controller_path to not write/read the
    # @controller_path class ivar from a worker Ractor. Also patches
    # action_methods, clear_action_methods!, abstract!, abstract?, and
    # _prefixes to route through IES or use the shareable fallback.
    def _install_abstract_controller_patch
      return if @abstract_controller_patched
      @abstract_controller_patched = true
      _register_patch :abstract_controller, "8.1"
      return unless defined?(::AbstractController::Base)
      ac = ::AbstractController::Base

      # Populate the shareable abstract registry from every loaded controller
      # class's @abstract ivar (set by abstract! / inherited at boot). Workers
      # read this via the patched abstract? (per-class values can't live in
      # per-Ractor IES).
      registry = {}
      ac.descendants.each do |klass|
        begin
          registry[klass] = klass.instance_variable_get(:@abstract) if klass.instance_variable_defined?(:@abstract)
        rescue StandardError => e
          # ignore — best-effort
        end
      end
      registry[ac] = ac.instance_variable_get(:@abstract) if ac.instance_variable_defined?(:@abstract)
      registry.freeze
      Ractor.make_shareable(registry)
      self._abstract_registry = registry
      ac.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def controller_path
          cache = (RactorRailsShim.storage[:ractor_rails_shim_controller_path_cache] ||= {})
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
          cache = (RactorRailsShim.storage[:ractor_rails_shim_action_methods_cache] ||= {})
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
          RactorRailsShim.storage[:ractor_rails_shim_action_methods_cache] = nil
        end

        # abstract! / abstract / abstract? — raw class ivar (@abstract), a
        # per-CLASS boolean. IES is per-Ractor (single value), so we can't use a
        # single IES key for all classes. Instead use a shareable registry
        # (Hash class→bool) built at prepare_for_ractors! time. Workers read
        # the registry; main reads its live @abstract ivar (set by abstract!
        # / inherited). `internal_methods` loops on abstract?.
        #
        # The registry is frozen with `Ractor.make_shareable` at install time so
        # it can travel the shared app graph. Mutating a frozen Hash raises
        # FrozenError, so `abstract!` only writes the live ivar (main) and
        # guards the registry write behind a mutability check. `abstract!`
        # after install in main is a no-op on the registry (already captured);
        # callers that need to flip a class to abstract post-install should
        # rebuild the registry (rare — abstract! is a boot-time declaration).
        def abstract!
          reg = RactorRailsShim._abstract_registry
          reg[self] = true if reg && !reg.frozen? && Ractor.main?
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
            cache = (RactorRailsShim.storage[:ractor_rails_shim_vp_prefixes_cache] ||= {})
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
            cache = (RactorRailsShim.storage[:ractor_rails_shim_url_for_action_methods_cache] ||= {})
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

      # Patch ActionController::Metal.controller_name (a class method). It
      # memoizes its computed String in a lazy class ivar (`@controller_name ||=`),
      # which a worker Ractor cannot write. Route the cache through
      # IsolatedExecutionState keyed by the class name so each Ractor builds its
      # own copy; the computation is deterministic from the class name.
      def _install_action_controller_controller_name_patch
        return if @action_controller_controller_name_patched
        @action_controller_controller_name_patched = true
        _register_patch :action_controller_controller_name, "8.1"
        return unless defined?(::ActionController::Metal)
        ::ActionController::Metal.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def controller_name
            key = :"ractor_rails_shim_controller_name_\#{name}"
            v = RactorRailsShim.storage[key]
            return v if v
            cn = (name.demodulize.delete_suffix("Controller").underscore unless anonymous?)
            RactorRailsShim.storage[key] = cn
            cn
          end
        RUBY
      end

      # In the shared :ractor graph, Devise's engine controllers (e.g.
      # Devise::SessionsController) end up with a nil `csrf_token_storage_strategy`
      # at request time — the value is dropped when make_app_shareable! deep-freezes
      # the app (RequestForgeryProtection sets it only on ActionController::Base.config,
      # and the per-controller frozen config copy loses it). A worker then raises
      # NoMethodError on `reset_csrf_token` during `reset_session` (logout /
      # sign_out). Guard the reset so a missing strategy is a no-op — `reset_session`
      # regenerates the session id anyway, discarding the CSRF token.
      def _install_csrf_reset_patch
        return if @csrf_reset_patched
        @csrf_reset_patched = true
        _register_patch :csrf_reset, "8.1"
        return unless defined?(::ActionController::RequestForgeryProtection)
        rfp = ::ActionController::RequestForgeryProtection
        rfp.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def reset_csrf_token(request) # :doc:
            request.env.delete(CSRF_TOKEN)
            strat = csrf_token_storage_strategy
            strat.reset(request) if strat
          end
        RUBY

        # `csrf_token_storage_strategy` and `forgery_protection_strategy` are
        # both delegated to the controller `config` (a class_attribute). In the
        # shared :ractor graph the per-controller frozen `config` copy loses
        # them, so a worker reads nil and CSRF token handling raises
        # ("undefined method 'fetch' for nil" / "undefined method 'new' for
        # nil"). Default to the standard SessionStore / Exception strategies so
        # token ISSUANCE and VALIDATION work in workers.
        #
        # NOTE: prepending to RequestForgeryProtection (a module) would NOT
        # reach the controllers, because ActionController::Base already
        # *included* it before this patch runs. Prepend to the BASE CLASS so
        # every controller (incl. Devise subclasses) picks up the default.
        # The defaults are referenced via their constant paths (not captured
        # locals) because `def` bodies do not close over enclosing locals.
        ::ActionController::Base.prepend(Module.new do
          def csrf_token_storage_strategy
            super || ::ActionController::RequestForgeryProtection::SessionStore.new
          end

          def forgery_protection_strategy
            super || ::ActionController::RequestForgeryProtection::ProtectionMethods::Exception
          end

          # Delegated to `config` (a class_attribute) which loses its value when
          # make_app_shareable! deep-freezes the shared graph, so a worker reads
          # nil. With a nil param key, form_authenticity_param reads params[nil]
          # and CSRF VALIDATION rejects every POST (even with a valid token),
          # because the token is carried under the real key (:authenticity_token).
          # Default to the standard param name so validation can find the token.
          def request_forgery_protection_token
            super || :authenticity_token
          end

          # `allow_forgery_protection` is delegated to `config` (a class_attribute
          # carrying the full, unshareable action_controller config graph). That
          # graph cannot be deep-frozen, so the shareable fallback built at
          # prepare_for_ractors! falls back to the EMPTY default — and a worker's
          # view `config` therefore reports `allow_forgery_protection = nil`,
          # making `protect_against_forgery?` false and suppressing CSRF token
          # issuance (no `<meta name="csrf-token">`, no hidden form field). The
          # CLASS-level `ActionController::Base.config.allow_forgery_protection`
          # IS correct in workers (it reads the frozen shareable class config),
          # so fall back to it when the per-instance/config value is unavailable.
          # The real value still wins whenever it is readable (main, or workers
          # whose config propagated), so apps that disable forgery protection
          # are unaffected.
          def allow_forgery_protection
            super || ::ActionController::Base.config.allow_forgery_protection
          end
        end)
      end

      # `logger` is delegated to `config` (a class_attribute) which loses its
      # value when make_app_shareable! deep-freezes the shared graph, so a
      # worker reads a nil/empty `config` and `logger` raises DelegationError
      # ("logger delegated to config, but config is nil"). `default_render`
      # (ImplicitRender) calls `logger` for its debug log, so a no-template
      # request (e.g. GET /) raises in workers. Fall back to the CLASS-level
      # `ActionController::Base.config.logger` — which IS correct in workers
      # (it reads the frozen shareable class config) — and finally to
      # `Rails.logger`. The real delegated logger still wins whenever it is
      # readable (main, or workers whose config propagated).
      def _install_controller_logger_patch
        return if @controller_logger_patched
        @controller_logger_patched = true
        _register_patch :controller_logger, "8.1"
        return unless defined?(::ActionController::Base)
        ::ActionController::Base.prepend(Module.new do
          def logger
            super
          rescue ActiveSupport::DelegationError
            ::ActionController::Base.config.logger || ::Rails.logger
          end

          # `config` is a class_attribute whose value cannot be deep-frozen, so
          # workers read nil (or a frozen empty default) instead of the real
          # action_controller config. Several code paths then call
          # `config.inheritable_copy` / `config.logger` and blow up
          # (NoMethodError / DelegationError) — including
          # ActionView::Helpers::ControllerHelper#assign_controller during
          # template rendering. Fall back to the CLASS-level
          # `ActionController::Base.config`, which IS correct in workers (it
          # reads the frozen shareable class config).
          def config
            cfg = super
            cfg || ::ActionController::Base.config
          rescue NoMethodError, ActiveSupport::DelegationError
            ::ActionController::Base.config
          end
        end)
        ::ActionController::Base.singleton_class.prepend(Module.new do
          def logger
            super
          rescue ActiveSupport::DelegationError
            ::ActionController::Base.config.logger || ::Rails.logger
          end
        end)
      end

      # `ParamsWrapper#_wrapper_options` is a class_attribute whose default
      # value (`ActionController::ParamsWrapper::Options.from_hash(format: [])`)
      # holds a `Mutex.new` and back-references the controller/model klass, so
      # it cannot be deep-frozen into the shared graph — its value is nil in a
      # worker Ractor (see the `#__class_attr__wrapper_options` boot warning).
      # `ParamsWrapper#_wrapper_formats` then calls `_wrapper_options.format`
      # and raises NoMethodError: private method `format' called for nil on
      # every wrapped request (e.g. POST /posts/:id/comments). Fall back to the
      # class_attribute's own declared default — wrapping disabled — whenever
      # the real value is unreadable in the worker. The default is built lazily
      # inside the method (never captured in a closure) so the prepended module
      # stays Ractor-shareable — the Options object (which owns a Mutex) only
      # ever lives in the worker that calls it.
      def _install_controller_params_wrapper_patch
        return if @controller_params_wrapper_patched
        @controller_params_wrapper_patched = true
        _register_patch :controller_params_wrapper, "8.1"
        return unless defined?(::ActionController::Base) &&
                      defined?(::ActionController::ParamsWrapper)
        ::ActionController::Base.prepend(Module.new do
          def _wrapper_options
            super ||
              ::ActionController::ParamsWrapper::Options.from_hash(format: [])
          rescue NoMethodError, ActiveSupport::DelegationError
            ::ActionController::ParamsWrapper::Options.from_hash(format: [])
          end
        end)
      end

      # Patch the flash-type helper methods (`notice`, `alert`, ...) defined by
      # `ActionController::Metal::Flash#add_flash_types` via
      # `define_method(type) { request.flash[type] }`. That block is compiled
      # in the MAIN Ractor, so calling it from a worker Ractor raises
      # "defined with an un-shareable Proc in a different Ractor". Redefine each
      # flash type as a string-eval'd method (no captured binding) so it is
      # callable from any Ractor. Called at prepare_for_ractors! time, after
      # the controllers are loaded and the types are known.
      def _install_flash_helpers_patch
        return if @flash_helpers_patched
        @flash_helpers_patched = true
        _register_patch :flash_helpers, "8.1"
        return unless defined?(::ActionController::Base)
        types = ::ActionController::Base._flash_types rescue []
        types.each do |type|
          ::ActionController::Base.class_eval "def #{type}; request.flash[#{type.inspect}]; end"
          ::ActionController::Base.send(:private, type) if ::ActionController::Base.private_method_defined?(type) rescue nil
        end
      end
  end
end
