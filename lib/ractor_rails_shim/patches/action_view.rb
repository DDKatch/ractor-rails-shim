# frozen_string_literal: true

# Patches for ActionView: LookupContext (default_formats defined via
# define_method(&block)), Template::Handlers, and PathRegistry.

module RactorRailsShim
  # Shareable, mutable module that holds compiled template methods
  # (e.g. `_app_views_...`). ActionView attaches compiled template methods to
  # `compiled_method_container`; the default returns a per-class container,
  # which isolates the shared application layout's compiled method to whichever
  # controller first rendered it (so other controllers raise NoMethodError on
  # the layout). Routing every view_context_class to this ONE shared module
  # makes compiled methods available to all controllers/workers. It is a plain
  # Module (shareable without freezing, so workers can still define methods on
  # it).
  SHAREABLE_COMPILED_MODULE = Module.new unless defined?(::RactorRailsShim::SHAREABLE_COMPILED_MODULE)

  # ActionView constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActionView::LookupContext::Accessors::DEFAULT_PROCS",
    "ActionView::Template::NONE",
    "ActionView::Template::Handlers::ERB::ENCODING_TAG",
    "ActionView::AbstractRenderer::RenderedTemplate::EMPTY_SPACER",
    "ActionView::Helpers::TagHelper::PRE_CONTENT_STRINGS",
    "ActionView::Helpers::AssetUrlHelper::ASSET_EXTENSIONS",
    "ActionView::Helpers::UrlHelper::BUTTON_TAG_METHOD_VERBS",
    "ActionView::Helpers::UrlHelper::STRINGIFIED_COMMON_METHODS",
  ])

  class << self
    # Patch `ActionView::Base.with_empty_template_cache` (action_view/base.rb:204)
    # to a block-free `def`. The original defines `compiled_method_container`
    # (instance + singleton) via `define_method(&block)` — an un-shareable Proc
    # compiled in the main Ractor that raises "defined with an un-shareable Proc
    # in a different Ractor" when a worker calls it. We also route compiled
    # template methods through ONE shared `SHAREABLE_COMPILED_MODULE` so the
    # `application` layout (and Devise shared partials) compile once and are
    # visible to every controller / worker Ractor.
    #
    # Installed EARLY via ActiveSupport.on_load(:action_view) (see core.rb
    # `install`) so it is in place before production eager load calls
    # `DetailsKey.view_context_class` -> `with_empty_template_cache`. Idempotent.
    def _install_with_empty_template_cache_patch
      return if @with_empty_template_cache_patched
      return unless defined?(::ActionView::Base) && Ractor.main?
      @with_empty_template_cache_patched = true
      _register_patch :with_empty_template_cache, "8.1"
      ::ActionView::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def with_empty_template_cache
          subclass = Class.new(self) do
            include RactorRailsShim::SHAREABLE_COMPILED_MODULE
            def compiled_method_container
              RactorRailsShim::SHAREABLE_COMPILED_MODULE
            end
            def self.compiled_method_container
              RactorRailsShim::SHAREABLE_COMPILED_MODULE
            end
            def inspect
              "#<ActionView::Base:\#{'%#016x' % (object_id << 1)}>"
            end
          end
          subclass
        end
      RUBY
    end

    def _install_lookup_context_patch
      return if @lookup_context_patched
      @lookup_context_patched = true
      _register_patch :lookup_context, "8.1"
      return unless defined?(::ActionView::LookupContext)
      # Force autoload of the nested ActionView::Template constants that the
      # patched details_cache_key references (Template::Types,
      # TemplateDetails::Requested). Constants are global, so defining them
      # here (main ractor) makes them visible to worker ractors, which cannot
      # autoload. Without this, the first template render in a worker dies on
      # `NameError: uninitialized constant ActionView::Template::TemplateDetails`.
      if Ractor.main? && defined?(::ActionView::Template)
        ::ActionView::Template::Types rescue nil
        ::ActionView::TemplateDetails rescue nil
      end
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

      # Redefine default_#{name} methods. register_detail (line 25 of
      # lookup_context.rb) defines these via Accessors.define_method(:"default_#{name}", &block)
      # — a Proc from the main ractor. Calling them from a worker raises
      # "defined with an un-shareable Proc in a different Ractor".
      # Trigger: when Accept: */* is sent, request.formats returns [Mime::ALL],
      # and LookupContext#formats= (the override at line 263) does
      # `values.concat(default_formats) if values.delete "*/*"` — Mime::ALL
      # compares == to "*/*", so delete removes it and default_formats is called.
      # Fix: call each block once in main, make the result shareable, and
      # redefine the method via string eval (no captured binding).
      accessors = ::ActionView::LookupContext::Accessors
      ::ActionView::LookupContext.registered_details.each do |name|
        block = accessors::DEFAULT_PROCS[name]
        next unless block
        begin
          value = block.call
        rescue
          next
        end
        begin
          value = Ractor.make_shareable(value)
        rescue
          value = value.dup.freeze rescue value
        end
        const_name = "SHIM_DEFAULT_#{name.upcase}_VALUE"
        verbose, $VERBOSE = $VERBOSE, nil
        accessors.const_set(const_name, value)
        $VERBOSE = verbose
        accessors.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def default_#{name}
            ::ActionView::LookupContext::Accessors::#{const_name}
          end
        RUBY
      end

      # Patch ActionView::Rendering::ClassMethods#view_context_class to read
      # from a shareable registry (populated in main) instead of building via
      # Class.new{...} blocks (un-shareable Proc from a worker). The built
      # class is made shareable; workers read it via the registry.
      if defined?(::ActionView::Rendering::ClassMethods)
        rcm = ::ActionView::Rendering::ClassMethods

        # `ActionView::Base.with_empty_template_cache` is patched separately and
        # EARLY (see _install_with_empty_template_cache_patch, installed via
        # ActiveSupport.on_load(:action_view) before eager load) because the
        # framework's original uses `define_method(:compiled_method_container)
        # { subclass }` — a block/Proc captured in the main Ractor that raises
        # "defined with an un-shareable Proc in a different Ractor" when a
        # worker calls it. In production `DetailsKey.view_context_class` calls
        # with_empty_template_cache during eager load, so the patch MUST be in
        # place before then.
        _install_with_empty_template_cache_patch if defined?(::ActionView::Base)

        # Build the per-controller view_context_class registry in main. We call
        # the ORIGINAL build_view_context_class directly (bypassing Rails'
        # inherit_view_context_class? short-circuit, which otherwise makes
        # subclasses reuse ActionController::Base's class built with a nil
        # `_routes` and thus NO route url_helpers). `routes` is forced to the
        # shareable Rails.application.routes when the controller's own `_routes`
        # is nil, so named helpers (new_post_path, etc.) are always present.
        if Ractor.main?
          registry = {}
          ::AbstractController::Base.descendants.each do |ctrl|
            begin
              routes = ctrl.respond_to?(:_routes) ? ctrl._routes : nil
              routes = ::Rails.application.routes if routes.nil? && ::Rails.respond_to?(:application) && ::Rails.application
              vcc = rcm.instance_method(:build_view_context_class).bind(ctrl).call(
                ::ActionView::LookupContext::DetailsKey.view_context_class,
                ctrl.respond_to?(:supports_path?) ? ctrl.supports_path? : true,
                routes,
                ctrl.respond_to?(:_helpers) ? ctrl._helpers : nil
              )
              registry[ctrl] = vcc if vcc
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
            return @view_context_class if Ractor.main? && instance_variable_defined?(:@view_context_class) && @view_context_class

            if Ractor.main?
              @view_context_class ||= build_view_context_class(
                ActionView::LookupContext::DetailsKey.view_context_class,
                supports_path?,
                _routes,
                _helpers
              )
              return @view_context_class
            end

            # Worker Ractor. The frozen shared controller class carries a
            # memoized @view_context_class built in main (in the registry) with
            # its proper route url_helpers + controller helpers. Look it up by
            # controller class; fall back to the shareable fallback class (built
            # in main with Rails.application.routes) for any controller not
            # present in the registry at prepare time.
            vcc = RactorRailsShim._view_context_registry[self]
            return vcc if vcc
            RactorRailsShim._view_context_fallback
          end

          # `inherit_view_context_class?` (action_view/rendering.rb:52) compares
          # `superclass._helpers` — and `_helpers` is defined via a block
          # (redefine_singleton_method) that cannot run in a worker Ractor
          # ("defined with an un-shareable Proc in a different Ractor"). Return
          # false so each controller builds its own view_context_class (the
          # normal Rails behaviour whenever _routes/_helpers differ), avoiding
          # the `_helpers` comparison entirely. Behaviour is identical in the
          # main Ractor (the inherited class would be equivalent).
          def inherit_view_context_class?
            false
          end
        RUBY
      end
      vcc_key = :ractor_rails_shim_lookup_context_view_context_class
      vcc_key_str = vcc_key.inspect
      CLASS_ATTRIBUTES << ["ActionView::LookupContext::DetailsKey", :view_context_class, vcc_key, nil]
      # Build it now in main and stash in IES so the fallback builder picks it up.
      if Ractor.main? && defined?(::ActionView::Base)
        ActiveSupport::IsolatedExecutionState[vcc_key] = ::ActionView::LookupContext::DetailsKey.view_context_class
        # Shareable fallback view_context_class for any controller not present in
        # the registry at prepare time. Subclasses ActionView::Base, so it
        # inherits the per-class compiled_method_container (self.class) and the
        # route url_helpers. build_view_context_class is a ClassMethods method on
        # controllers, so invoke it via the unbound method bound to
        # ActionController::Base.
        fallback = rcm.instance_method(:build_view_context_class).bind(::ActionController::Base).call(
          ::ActionView::LookupContext::DetailsKey.view_context_class,
          true,
          (defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application) ? ::Rails.application.routes : nil,
          nil
        )
        Ractor.make_shareable(fallback) rescue nil
        self._view_context_fallback = fallback
      end

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
              unless ::ActionView::Template::Types.valid_symbols?(formats)
                details = details.dup
                details[:formats] &= ::ActionView::Template::Types.symbols
              end
            end
            details_keys[details] ||= ::ActionView::TemplateDetails::Requested.new(**details)
          end
        end
      RUBY
    end

    def _install_template_handlers_patch
      return if @template_handlers_patched
      @template_handlers_patched = true
      _register_patch :template_handlers, "8.1"
      return unless defined?(::ActionView::Template::Handlers)
      # Eager-load the handler classes in main so workers don't need to
      # autoload them (workers can't autoload).
      if Ractor.main?
        ::ActionView::Template::Handlers::Raw rescue nil
        ::ActionView::Template::Handlers::ERB rescue nil
        ::ActionView::Template::Handlers::Html rescue nil
        ::ActionView::Template::Handlers::Builder rescue nil
      end
      h = ::ActionView::Template::Handlers
      th_key = :ractor_rails_shim_av_template_handlers
      dth_key = :ractor_rails_shim_av_default_template_handlers
      th_key_str = th_key.inspect
      dth_key_str = dth_key.inspect
      # The handler registry lives in class variables (@@template_handlers,
      # @@default_template_handlers, @@template_extensions) whose values are
      # mutable Hashes holding handler instances — and an unshareable `:ruby`
      # lambda. A worker Ractor cannot read these class vars. Route the
      # registry through IsolatedExecutionState: each Ractor builds its own
      # handler map (the defaults are deterministic), and in main we seed from
      # the live class var (capturing any custom handlers gems registered at
      # boot). The `:ruby` lambda makes the map unshareable, so the old
      # SHAREABLE_FALLBACK approach (which skips unshareable values) left
      # workers with an empty map. These are instance methods (Handlers is
      # extended into ActionView::Template, and the render path calls them on
      # the Template instance), so they must be defined on the module itself,
      # not just the singleton class.
      h.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def self._ractor_rails_shim_handlers
          map = ActiveSupport::IsolatedExecutionState[#{th_key_str}]
          return map unless map.nil?
          if Ractor.main?
            cv = class_variable_get(:@@template_handlers) rescue nil
            cv = nil if cv && cv.empty?
            if cv
              ActiveSupport::IsolatedExecutionState[#{th_key_str}] = cv
              return cv
            end
          end
          built = {
            raw: ::ActionView::Template::Handlers::Raw.new,
            erb: ::ActionView::Template::Handlers::ERB.new,
            html: ::ActionView::Template::Handlers::Html.new,
            builder: ::ActionView::Template::Handlers::Builder.new,
            ruby: ->(_, source) { source },
          }
          ActiveSupport::IsolatedExecutionState[#{th_key_str}] = built
          built
        end

        def self._ractor_rails_shim_persist(map)
          ActiveSupport::IsolatedExecutionState[#{th_key_str}] = map
          class_variable_set(:@@template_handlers, map) if Ractor.main?
        end

        def self.extensions
          self._ractor_rails_shim_handlers.keys
        end

        def registered_template_handler(extension)
          extension && ::ActionView::Template::Handlers._ractor_rails_shim_handlers[extension.to_sym]
        end

        def handler_for_extension(extension)
          registered_template_handler(extension) || ::ActionView::Template::Handlers::ERB.new
        end

        def template_handler_extensions
          ::ActionView::Template::Handlers._ractor_rails_shim_handlers.keys.map(&:to_s).sort
        end

        def register_template_handler(*extensions, handler)
          map = ::ActionView::Template::Handlers._ractor_rails_shim_handlers.dup
          extensions.each { |ext| map[ext.to_sym] = handler }
          ::ActionView::Template::Handlers._ractor_rails_shim_persist(map)
        end

        def unregister_template_handler(*extensions)
          map = ::ActionView::Template::Handlers._ractor_rails_shim_handlers.dup
          extensions.each { |ext| map.delete(ext.to_sym) }
          ::ActionView::Template::Handlers._ractor_rails_shim_persist(map)
        end

        def register_default_template_handler(extension, klass)
          register_template_handler(extension, klass)
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

    # Patch ActionView::FileSystemResolver#_find_all. The original reads the
    # resolver's `@unbound_templates` cache, which `make_app_shareable!`
    # rewrites from a Concurrent::Map into a frozen Hash (Concurrent::Map
    # refuses #freeze). The original then calls `cache.compute_if_absent`
    # (a Concurrent::Map API) on it, which a frozen Hash lacks -> NoMethodError
    # in a worker Ractor. Route the per-virtual-path cache through
    # IsolatedExecutionState instead: each Ractor builds its own mutable Hash
    # (deterministic from disk via `unbound_templates_from_path`), so the
    # frozen shareable app graph is never mutated.
    def _install_action_view_resolver_patch
      return if @action_view_resolver_patched
      @action_view_resolver_patched = true
      _register_patch :action_view_resolver, "8.1"
      return unless defined?(::ActionView::FileSystemResolver)
      # Eager-load nested constants referenced below (workers can't autoload).
      if Ractor.main?
        ::ActionView::TemplateDetails rescue nil
        ::ActionView::TemplatePath rescue nil
      end
      ::ActionView::FileSystemResolver.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _find_all(name, prefix, partial, details, key, locals)
          requested_details = key || ::ActionView::TemplateDetails::Requested.new(**details)
          virtual = ::ActionView::TemplatePath.virtual(name, prefix, partial)
          # Key the cache by resolver path AND virtual path: each resolver
          # (app/views, each gem) has its own @path and its own templates.
          # Keying only by virtual path would let the first resolver poison
          # the cache for all others (e.g. app/views caches [] for
          # devise/sessions/new, hiding the template that lives in the
          # devise gem resolver).
          cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_resolver_cache] ||= {})
          cache_key = [@path, virtual]
          unbound_templates =
            if cache.key?(cache_key)
              cache[cache_key]
            else
              path = ::ActionView::TemplatePath.build(name, prefix, partial)
              tmpls = unbound_templates_from_path(path)
              cache[cache_key] = tmpls
              tmpls
            end
          filter_and_sort_by_details(unbound_templates, requested_details).map do |unbound_template|
            unbound_template.bind_locals(locals)
          end
        end
      RUBY

      # Patch ActionView::Resolver::PathParser#parse. The resolver's
      # @path_parser instance is part of the shareable app graph frozen by
      # make_app_shareable!, and the original method memoizes its compiled
      # regex in `@regex ||= build_path_regex` — assigning @regex on a frozen
      # object raises FrozenError in a worker Ractor. Route the memoization
      # through IsolatedExecutionState keyed by the parser's object_id, so each
      # Ractor compiles its own regex once without mutating the frozen object.
      if defined?(::ActionView::Resolver::PathParser)
        pp = ::ActionView::Resolver::PathParser
        pp_key = :ractor_rails_shim_path_parser_regex
        pp_key_str = pp_key.inspect
        pp.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def parse(path)
            regex = ActiveSupport::IsolatedExecutionState[:"#{pp_key_str}_\#{object_id}"] ||= build_path_regex
            match = regex.match(path)
            path = ::ActionView::TemplatePath.build(match[:action], match[:prefix] || "", !!match[:partial])
            details = ::ActionView::TemplateDetails.new(
              match[:locale]&.to_sym,
              match[:handler]&.to_sym,
              match[:format]&.to_sym,
              match[:variant]&.to_sym
            )
            ::ActionView::Resolver::PathParser::ParsedPath.new(path, details)
          end
        RUBY
      end
    end

    # Patch ActionView::AbstractRenderer::ObjectRendering#partial_path. The
    # original reads `PREFIXED_PARTIAL_NAMES` — a `Concurrent::Map` constant
    # (nested Concurrent::Maps) — and writes a nested entry via
    # `PREFIXED_PARTIAL_NAMES[@context_prefix][path] ||= ...`. Concurrent::Map
    # is intrinsically unshareable (it refuses #freeze), so a worker Ractor
    # cannot read the constant NOR write to it. Redefine the method to use a
    # per-Ractor Hash via IsolatedExecutionState (each Ractor builds its own
    # cache from `merge_prefix_into_object_path`, which is deterministic).
    def _install_action_view_partial_path_patch
      return if @action_view_partial_path_patched
      @action_view_partial_path_patched = true
      _register_patch :action_view_partial_path, "8.1"
      return unless defined?(::ActionView::AbstractRenderer)
      ::ActionView::AbstractRenderer::ObjectRendering.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def partial_path(object, view)
          object = object.to_model if object.respond_to?(:to_model)
          path = if object.respond_to?(:to_partial_path)
            object.to_partial_path
          else
            raise ArgumentError.new("\#{object.inspect}' is not an ActiveModel-compatible object. It must implement #to_partial_path.")
          end
          if view.prefix_partial_path_with_controller_namespace
            cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_prefixed_partial_names] ||= {})
            cache[@context_prefix] ||= {}
            cache[@context_prefix][path] ||= merge_prefix_into_object_path(@context_prefix, path.dup)
          else
            path
          end
        end
      RUBY
    end

    # Patch ActionView::Helpers::Tags::TextField.field_type (and the subclasses
    # EmailField/PasswordField/... that inherit it). The original memoizes its
    # computed String in a lazy class ivar (`@field_type ||= name...`). The
    # class ivar is per-subclass and unshareable-writable from a worker Ractor.
    # Route the cache through IsolatedExecutionState keyed by the class name so
    # each Ractor builds its own copy; the computation is deterministic.
    def _install_action_view_field_type_patch
      return if @action_view_field_type_patched
      @action_view_field_type_patched = true
      _register_patch :action_view_field_type, "8.1"
      return unless defined?(::ActionView::Helpers::Tags::TextField)
      tf = ::ActionView::Helpers::Tags::TextField
      tf.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def field_type
          key = :"ractor_rails_shim_field_type_\#{name}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v if v
          ft = name.split("::").last.sub("Field", "").downcase
          ActiveSupport::IsolatedExecutionState[key] = ft
          ft
        end
      RUBY
    end

    # Patch ActionView::Helpers::OutputSafetyHelper#safe_join. Its default
    # separator parameter is `sep = $,` — a reference to the `$` global, which a
    # worker Ractor cannot read (Ractor::IsolationError: can not access global
    # variable $,). The `$` global is nil in every normal Rails process, so
    # defaulting to nil reproduces the identical behaviour without touching the
    # global.
    def _install_action_view_safe_join_patch
      return if @action_view_safe_join_patched
      @action_view_safe_join_patched = true
      _register_patch :action_view_safe_join, "8.1"
      return unless defined?(::ActionView::Helpers::OutputSafetyHelper)
      ::ActionView::Helpers::OutputSafetyHelper.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def safe_join(array, sep = nil)
          sep = ERB::Util.unwrapped_html_escape(sep)
          array.flatten.map! { |i| ERB::Util.unwrapped_html_escape(i) }.join(sep).html_safe
        end
      RUBY
    end

  end
end
