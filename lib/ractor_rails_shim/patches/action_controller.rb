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
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_param_encodings]
          end
          if enc && enc.has_key?(action.to_s)
            enc[action.to_s]
          end
        end
      RUBY
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
            v = ActiveSupport::IsolatedExecutionState[key]
            return v if v
            cn = (name.demodulize.delete_suffix("Controller").underscore unless anonymous?)
            ActiveSupport::IsolatedExecutionState[key] = cn
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
