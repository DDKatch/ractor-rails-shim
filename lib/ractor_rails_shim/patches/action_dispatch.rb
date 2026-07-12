# frozen_string_literal: true

# Patches for ActionDispatch: ExceptionWrapper (reads @@rescue_responses
# directly), and Request.parameter_parsers.

module RactorRailsShim
  # ActionDispatch + Mime constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActionDispatch::FileHandler::PRECOMPRESSED",
    "ActionDispatch::SSL::PERMANENT_REDIRECT_REQUEST_METHODS",
    "ActionDispatch::HostAuthorization::VALID_IP_HOSTNAME",
    "ActionDispatch::HostAuthorization::ALLOWED_HOSTS_IN_DEVELOPMENT",
      "ActionDispatch::Request::HTTP_METHODS",
      "ActionDispatch::Request::HTTP_METHOD_LOOKUP",
      "ActionDispatch::Request::LOCALHOST",
    "ActionDispatch::DebugView::RESCUES_TEMPLATE_PATHS",
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
        "ActionView::Helpers::ControllerHelper::CONTROLLER_DELEGATES",
      ])

  # Source-location constants used by make_app_shareable!'s proc-replacement
  # graph traversal (moved here from make_shareable.rb so each concern's pieces
  # live together).
  SSL_LOC = "/active_dispatch/middleware/ssl.rb".freeze
  COOKIE_LOC = "/session/cookie_store.rb".freeze
  MAPPER_LOC = "/action_dispatch/routing/mapper.rb".freeze

  class << self
    # Shareable callable replacements for ActionDispatch/ActionController
    # self-capturing Procs (moved here from make_shareable.rb). Defined via
    # string eval on the singleton class so they're referenced the same way the
    # original code did (the engine resolves them as RactorRailsShim singleton
    # class constants; specs access via RactorRailsShim.singleton_class.const_get).
    module_eval <<-RUBY, __FILE__, __LINE__ + 1
      class RequestCallable
        def initialize(method_name); @method_name = method_name; end
        def call(request, response = nil); request.__send__(@method_name); end
      end
      class StrategyServe
        def call(app, req); app.serve(req); end
      end
      class StrategyCall
        def call(app, req); app.call(req.env); end
      end
    RUBY

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
      # Also patch the class method (status_code_for_exception) that reads
      # @@rescue_responses directly — called by ActionController::Instrumentation
      # at request time. Route through the mattr reader (which the shim already
      # reroutes through IES).
      ::ActionDispatch::ExceptionWrapper.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def status_code_for_exception(class_name)
          ActionDispatch::Response.rack_status_code(rescue_responses[class_name])
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

    # ActionDispatch::QueryParser.each_pair returns `enum_for(:each_pair, s,
    # separator)` when called without a block. The Enumerator wraps a Proc that
    # was compiled in the main Ractor, so when a worker Ractor iterates it
    # (`pairs.each` inside ParamBuilder#from_pairs) Ruby raises "defined with an
    # un-shareable Proc in a different Ractor". Redefine it to materialize into a
    # plain (shareable) frozen Array using a block-free loop, so worker Ractors
    # can parse form/query pairs without crossing Ractor boundaries.
    def _install_query_parser_patch
      return if @query_parser_patched
      @query_parser_patched = true
      return unless defined?(::ActionDispatch::QueryParser)
      ::ActionDispatch::QueryParser.singleton_class.module_eval <<-'RUBY', __FILE__, __LINE__ + 1
        def each_pair(s, separator = nil)
          return _materialized_pairs(s, separator) unless block_given?
          s ||= ""
          splitter =
            if separator
              ::ActionDispatch::QueryParser::COMMON_SEP[separator] || /[#{separator}] */n
            else
              ::ActionDispatch::QueryParser::DEFAULT_SEP
            end
          s.split(splitter).each do |part|
            next if part.empty?
            k, v = part.split("=", 2)
            k = URI.decode_www_form_component(k)
            v &&= URI.decode_www_form_component(v)
            yield k, v
          end
          nil
        end

        def _materialized_pairs(s, separator)
          s ||= ""
          splitter =
            if separator
              ::ActionDispatch::QueryParser::COMMON_SEP[separator] || /[#{separator}] */n
            else
              ::ActionDispatch::QueryParser::DEFAULT_SEP
            end
          parts = s.split(splitter)
          result = []
          i = 0
          while i < parts.length
            part = parts[i]
            i += 1
            if part.empty?
              next
            end
            kv = part.split("=", 2)
            k = URI.decode_www_form_component(kv[0])
            v = kv[1] && URI.decode_www_form_component(kv[1])
            result << [k, v]
          end
          result.freeze
        end
      RUBY
    end

    # Patch ActionDispatch::Routing::RouteSet::MountedHelpers#main_app (and
    # its _main_app worker). main_app is `define_method`-ed at boot capturing
    # the MAIN ractor's RouteSet + url_helpers in its block binding, so
    # calling it from a worker Ractor raises "defined with an un-shareable
    # Proc in a different Ractor". Devise's _devise_route_context calls
    # `send(:main_app)` to get the route context for its url helpers. Redefine
    # via string eval, building the RoutesProxy from the shareable RouteSet
    # (RactorRailsShim::SHAREABLE_ROUTES) so workers get a valid context.
    def _install_action_dispatch_mounted_helpers_patch
      return if @mounted_helpers_patched
      @mounted_helpers_patched = true
      _register_patch :mounted_helpers, "8.1"
      return unless defined?(::ActionDispatch::Routing::RouteSet::MountedHelpers)
      mh = ::ActionDispatch::Routing::RouteSet::MountedHelpers
      return unless mh.method_defined?(:main_app)
      mh.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def _main_app
          ::ActionDispatch::Routing::RoutesProxy.new(
            RactorRailsShim::SHAREABLE_ROUTES,
            _routes_context,
            RactorRailsShim::SHAREABLE_ROUTES.url_helpers,
            nil
          )
        end
        def main_app
          @_main_app ||= _main_app
        end
      RUBY
    end

    # Patch ActionDispatch::Routing::RouteSet URL generation. The named route
    # helpers (`post_path`, `session_path`, ...) are generated at boot in the
    # main Ractor by `RouteSet#add`, which captures the `PATH` / `UNKNOWN`
    # lambda constants (route_set.rb:349-350) into each helper's `url_strategy`
    # ivar. Those lambdas were defined in the main Ractor, so calling them from
    # a worker Ractor raises `RuntimeError: defined with an un-shareable Proc in
    # a different Ractor`. Replace them with shareable Callable objects (Plain
    # old objects with a `#call` method, made shareable via
    # `Ractor.make_shareable`) that delegate to `ActionDispatch::Http::URL`
    # (module methods, callable from any Ractor).
    def _install_action_dispatch_routing_patch
      return if @action_dispatch_routing_patched
      @action_dispatch_routing_patched = true
      _register_patch :action_dispatch_routing, "8.1"
      return unless defined?(::ActionDispatch::Routing::RouteSet)
      return unless defined?(::ActionDispatch::Http::URL)

      # Shareable Callable replacements for the PATH / UNKNOWN lambda constants.
      unless RactorRailsShim.const_defined?(:AVPathStrategy)
        RactorRailsShim.const_set(:AVPathStrategy,
          Ractor.make_shareable(Object.new.tap do |o|
            def o.call(options)
              ActionDispatch::Http::URL.path_for(options)
            end
          end))
      end
      unless RactorRailsShim.const_defined?(:AVUnknownStrategy)
        RactorRailsShim.const_set(:AVUnknownStrategy,
          Ractor.make_shareable(Object.new.tap do |o|
            def o.call(options)
              ActionDispatch::Http::URL.url_for(options)
            end
          end))
      end

      rs = ::ActionDispatch::Routing::RouteSet
      # `RouteSet::PATH` / `RouteSet::UNKNOWN` (route_set.rb:349-350) are lambdas
      # defined in the main Ractor. They are referenced as default parameter
      # values (`def url_for(..., url_strategy = UNKNOWN, ...)`) and inside
      # `path_for`/`define_url_helper`. Reading those constants from a worker
      # Ractor raises `Ractor::IsolationError: can not access non-shareable
      # objects in constant ...UNKNOWN`. Replace them with the shareable
      # Callable objects (which perform the identical `ActionDispatch::Http::URL`
      # lookups) so workers read a shareable constant instead of an unshareable
      # lambda. Behaviour is unchanged in main (same `#call(options)` contract).
      unless rs.const_defined?(:PATH) && Ractor.shareable?(rs.const_get(:PATH))
        verbose = $VERBOSE
        $VERBOSE = nil
        rs.const_set(:PATH, RactorRailsShim::AVPathStrategy)
        rs.const_set(:UNKNOWN, RactorRailsShim::AVUnknownStrategy)
        $VERBOSE = verbose if defined?(verbose)
      end
      # `ActionDispatch::Journey::Router::Utils::ENCODER` (`UriEncoder.new`) and
      # its sibling constants (`DEC2HEX`, `EMPTY`, `US_ASCII`, the unreserved/
      # segment regexes, ...) are referenced by `escape_path`/`escape_segment`,
      # which the journey URL formatter invokes while building a path in a worker
      # Ractor. An unfrozen object/array/string held in a constant is unshareable,
      # so workers reading it raise IsolationError. Freeze each constant in place
      # (via `Ractor.make_shareable`) so the shareable-frozen values are readable
      # from any Ractor.
      if defined?(::ActionDispatch::Journey::Router::Utils)
        utu = ::ActionDispatch::Journey::Router::Utils
        utu.constants.each do |c|
          begin
            v = utu.const_get(c)
            Ractor.make_shareable(v) if v && !Ractor.shareable?(v)
          rescue
            nil
          end
        end
      end
      # `RouteSet::RESERVED_OPTIONS` (route_set.rb:838) is a mutable Array used
      # as a default parameter value in `url_for`/`path_for`. A non-frozen Array
      # is unshareable, so workers reading the constant raise IsolationError.
      # Freeze it in place so the constant becomes shareable.
      begin
        Ractor.make_shareable(rs.const_get(:RESERVED_OPTIONS))
      rescue
        nil
      end
      # Warm the lazy (memoized) caches on every Journey route and its
      # Path::Pattern BEFORE `make_app_shareable!` deep-freezes them. Several of
      # these caches are filled with `||=` (e.g. `Route#parts`,
      # `Route#required_parts`, `Route#required_defaults`,
      # `Path::Pattern#requirements_for_missing_keys_check`, `#to_regexp`,
      # `#offsets`, `#required_names`, `#optional_names`). They are computed
      # deterministically, but assigning the memoized ivar on a frozen object
      # from a worker Ractor raises FrozenError. Computing them here (in main,
      # while the objects are still mutable) populates the ivars so the frozen,
      # shared copies already hold the values and workers only read them.
      if Ractor.main? && defined?(::Rails) && ::Rails.application
        begin
          rset = ::Rails.application.routes
          all = []
          all.concat(rset.named_routes.send(:routes).values) rescue nil
          all.concat(rset.set.routes) rescue nil
          all.uniq.each do |route|
            next unless route.respond_to?(:path)
            route.parts rescue nil
            route.required_parts rescue nil
            route.required_defaults rescue nil
            p = route.path
            p.requirements_for_missing_keys_check rescue nil
            p.to_regexp rescue nil
            p.offsets rescue nil
            p.required_names rescue nil
            p.optional_names rescue nil
          end
        rescue
          nil
        end
      end
      # Capture the (shareable) RouteSet so workers can build URLs without
      # calling `#_routes` — which is `define_method(:_routes) { @_routes ||
      # routes }` (route_set.rb:612), a block capturing the main Ractor's
      # `routes` reference. Calling that block from a worker raises
      # "defined with an un-shareable Proc in a different Ractor". We stash the
      # RouteSet as a shareable constant and point `_routes` at it.
      if Ractor.main?
        begin
          routes = Rails.application.routes if defined?(::Rails) && ::Rails.application
          unless routes.nil?
            verbose = $VERBOSE
            $VERBOSE = nil
            RactorRailsShim.const_set(:SHAREABLE_ROUTES, routes) unless RactorRailsShim.const_defined?(:SHAREABLE_ROUTES)
          end
        rescue
          nil
        ensure
          $VERBOSE = verbose if defined?(verbose)
        end
      end

      # RouteSet#url_for receives url_strategy (the captured PATH/UNKNOWN
      # lambda) and calls `url_strategy.call options` internally. Coerce a
      # non-shareable strategy to the shareable Callable before delegating.
      unless rs.method_defined?(:url_for_without_shim)
        rs.alias_method(:url_for_without_shim, :url_for)
      end
      rs.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def url_for(options, route_name = nil, url_strategy = UNKNOWN, method_name = nil, reserved = RESERVED_OPTIONS)
          url_strategy = RactorRailsShim::AVUnknownStrategy unless Ractor.shareable?(url_strategy)
          url_for_without_shim(options, route_name, url_strategy, method_name, reserved)
        end
      RUBY

      # OptimizedUrlHelper#call invokes `url_strategy.call options` DIRECTLY
      # (route_set.rb:228) without going through url_for, so the coercion above
      # doesn't cover it. Redefine it to call the shareable strategy Callable
      # (the one passed in by our redefined helper methods), replicating the
      # original body exactly otherwise.
      ::ActionDispatch::Routing::RouteSet::NamedRouteCollection::UrlHelper::OptimizedUrlHelper.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def call(t, method_name, args, inner_options, url_strategy)
          if args.size == arg_size && !inner_options && optimize_routes_generation?(t)
            options = t.url_options.merge @options
            path = optimized_helper(args)
            path << "/" if options[:trailing_slash] && !path.end_with?("/")
            options[:path] = path
            original_script_name = options.delete(:original_script_name)
            script_name = t._routes.find_script_name(options)
            if original_script_name
              script_name = original_script_name + script_name
            end
            options[:script_name] = script_name
            strat = Ractor.shareable?(url_strategy) ? url_strategy : RactorRailsShim::AVPathStrategy
            strat.call(options)
          else
            super
          end
        end
      RUBY

      # The base (non-optimized) `UrlHelper#call` (route_set.rb:278) is hit
      # whenever a helper is generated as a plain `UrlHelper` (e.g. our re-run
      # loop) or when optimization is skipped. The original reads `t.url_options`
      # and `t._routes`, both of which assume `t` is a controller/view context
      # whose `_routes`/`url_options` are reachable from a worker. In practice
      # `t` may be the `NamedRouteCollection` (helpers proxy) or any object that
      # lacks these. Route both through the shareable RouteSet / url-options
      # snapshot, falling back to `t`'s own accessors only when it actually
      # provides them (real controller/view). This makes path generation
      # (host-independent) work from any Ractor regardless of `t`.
      ::ActionDispatch::Routing::RouteSet::NamedRouteCollection::UrlHelper.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def call(t, method_name, args, inner_options, url_strategy)
          begin
            controller_options = t.url_options
          rescue
            controller_options = RactorRailsShim::URL_OPTIONS_DEFAULTS || {}
          end
          options = controller_options.merge @options
          hash = handle_positional_args(controller_options, inner_options || {}, args, options, @segment_keys)
          begin
            routes = t._routes
          rescue
            routes = RactorRailsShim::SHAREABLE_ROUTES
          end
          routes.url_for(hash, route_name, url_strategy, method_name)
        end
      RUBY

      # Named route helpers (`post_path`, `post_url`, ...) are generated by
      # `NamedRouteCollection#define_url_helper` (route_set.rb:333) via
      # `mod.define_method(name) { |*args| ... helper.call(...) }` — a BLOCK that
      # captures the `helper` object (an OptimizedUrlHelper holding the route)
      # and the `url_strategy` lambda (PATH/UNKNOWN, both defined in main).
      # Calling that block from a worker Ractor raises
      # "defined with an un-shareable Proc in a different Ractor" before any
      # code runs. Patch `define_url_helper` to (a) make the helper shareable
      # via `Ractor.make_shareable` (deep-freeze; routes are read-only after
      # boot) and stash it in a shareable Hash keyed by name, and (b) define the
      # method with a STRING (no captured binding) that references the Hash and
      # the shareable strategy Callable directly.
      unless RactorRailsShim.const_defined?(:URL_HELPERS)
        RactorRailsShim.const_set(:URL_HELPERS, {})
      end
      nrc = ::ActionDispatch::Routing::RouteSet::NamedRouteCollection
      unless nrc.method_defined?(:define_url_helper_without_shim)
        nrc.alias_method(:define_url_helper_without_shim, :define_url_helper)
      end
      nrc.define_method(:define_url_helper) do |mod, name, helper, url_strategy|
        begin
          # Detach the helper from the live route object before deep-freezing
          # it for cross-Ractor sharing. The non-optimized UrlHelper#call only
          # needs @options / @segment_keys / @route_name to build the options
          # hash and then delegates to `t._routes.url_for(route_name, ...)`,
          # which looks the route up in the (shareable) RouteSet by name. The
          # @route reference would pull the whole route graph into the freeze,
          # freezing objects that make_app_shareable! must still be able to
          # mutate (e.g. Devise route constraints) -> FrozenError.
          if helper.respond_to?(:instance_variable_get)
            helper.instance_variable_set(:@route, nil) rescue nil
            opts = helper.instance_variable_get(:@options)
            helper.instance_variable_set(:@options, opts.dup.freeze) rescue nil
            segs = helper.instance_variable_get(:@segment_keys)
            helper.instance_variable_set(:@segment_keys, segs.dup.freeze) rescue nil
          end
          helper = Ractor.make_shareable(helper)
        rescue
          nil
        end
        RactorRailsShim::URL_HELPERS[name] = helper
        strategy_const = url_strategy.equal?(::ActionDispatch::Routing::RouteSet::PATH) ?
          "AVPathStrategy" : "AVUnknownStrategy"
        mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{name}(*args)
            last = args.last
            options = \\
              case last
              when ::Hash
                args.pop
              when ::ActionController::Parameters
                args.pop.to_h
              end
            RactorRailsShim::URL_HELPERS[#{name.inspect}].call(
              self, #{name.inspect}, args, options, RactorRailsShim::#{strategy_const})
          end
        RUBY
      end

      # Re-run the (now patched) helper generation for every route already
      # drawn at boot, so the helpers the app actually uses are worker-safe.
      # Routes are drawn during `Rails.application.initialize!`, which runs
      # before `prepare_for_ractors!`, so the originals are still block-based.
      if Ractor.main? && defined?(::Rails) && ::Rails.application
        begin
          named = ::Rails.application.routes.named_routes
          path_mod = named.instance_variable_get(:@path_helpers_module)
          url_mod = named.instance_variable_get(:@url_helpers_module)
          named.send(:routes).each do |route_name, route|
            # Build the helper directly via `UrlHelper.new` (NOT `UrlHelper.create`,
            # which calls `optimize_helper?` -> `route.glob?` -> `route.path.ast.glob?`
            # and `route.path.ast` is nil by the time routes are finalized post-boot).
            helper = ::ActionDispatch::Routing::RouteSet::NamedRouteCollection::UrlHelper.new(
              route, route.defaults, route_name)
            named.define_url_helper(path_mod, :"#{route_name}_path", helper, ::ActionDispatch::Routing::RouteSet::PATH) if path_mod
            named.define_url_helper(url_mod, :"#{route_name}_url", helper, ::ActionDispatch::Routing::RouteSet::UNKNOWN) if url_mod
          end
          verbose = $VERBOSE
          $VERBOSE = nil
          RactorRailsShim.const_set(:URL_HELPERS, Ractor.make_shareable(RactorRailsShim::URL_HELPERS)) unless Ractor.shareable?(RactorRailsShim::URL_HELPERS)
        rescue
          nil
        ensure
          $VERBOSE = verbose if defined?(verbose)
        end
      end

      # `ActionController::UrlFor#url_options` (action_controller/metal/url_for.rb:45)
      # builds its option hash from `request.host` / `request.optional_port` /
      # `request.protocol` / `request.path_parameters` and merges in
      # `default_url_options`. The controller instance rendered in a worker Ractor
      # has a `request` built from the shared Rack env, but the values it returns
      # (and the `default_url_options` class value, an unshareable Hash stored as a
      # class ivar on ActionController::Base) cannot be read/called from a worker
      # without raising Ractor isolation errors. For path-only helpers (the common
      # case in views) the host/port/protocol are irrelevant, and `default_url_options`
      # is the same deterministic value everywhere, so capture it once in main as a
      # shareable snapshot and have workers use it directly, skipping the
      # request-derived portion.
      unless RactorRailsShim.const_defined?(:URL_OPTIONS_DEFAULTS)
        begin
          if Ractor.main? && defined?(::ActionController::Base)
            defaults = ::ActionController::Base.default_url_options
            defaults = defaults.dup.freeze if defaults.respond_to?(:freeze)
            RactorRailsShim.const_set(:URL_OPTIONS_DEFAULTS, Ractor.make_shareable(defaults))
          end
        rescue
          nil
        end
      end
      if defined?(::ActionController::UrlFor)
        ::ActionController::UrlFor.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def url_options
            return super if Ractor.main?
            @_url_options ||= begin
              opts = (RactorRailsShim::URL_OPTIONS_DEFAULTS || {}).dup
              begin
                req = request if respond_to?(:request)
                if req
                  opts[:host] = req.host if opts[:host].nil? && req.respond_to?(:host)
                  opts[:protocol] = req.protocol if opts[:protocol].nil? && req.respond_to?(:protocol)
                  opts[:port] = req.port if opts[:port].nil? && req.respond_to?(:port)
                  opts[:_recall] = req.path_parameters if req.respond_to?(:path_parameters)
                end
              rescue
                nil
              end
              opts.freeze
            end
          end
        RUBY
      end

      # NOTE: the block-based `_routes` accessors that break workers are now
      # fixed at their source by `_install_url_helpers_patch` (patches/
      # url_helpers.rb), which intercepts `Module#redefine_singleton_method`
      # / `Module#define_method` for `:_routes` and replaces the main-Ractor
      # block with a string-eval'd method returning `Rails.application.routes`.
      # No per-class enumeration needed.
    end

    # Make Journey route recognition work under kino :ractor.
    #
    # The shared app graph (frozen + made shareable by make_app_shareable!)
    # already carries the routes' ast and the GTG simulator. The simulator,
    # however, is normally UNshareable because TransitionTable seeds @memos
    # with a default-Proc Hash (`Hash.new { |h,k| h[k] = [] }`), and because
    # its @memos holds the per-route Route objects whose constraint Procs can't
    # cross Ractor boundaries. The default Proc is the only thing *we* can fix;
    # the Route constraint Procs are instead made shareable by make_app_shareable!
    # when it freezes the whole graph (its proc-replacement pass rewrites them).
    #
    # So the plan:
    #   1. Patch TransitionTable to use a plain Hash + `add_memo` using `||= []`
    #      (behavior-identical, but shareable once Route memos are frozen).
    #   2. Warm + cache `@ast` / `@simulator` on the live Routes object AFTER
    #      make_app_shareable!'s route precompute (which reloads/resets the
    #      routes) and BEFORE Ractor.make_shareable freezes the graph. Once
    #      frozen into the shared graph, worker Ractors read the cached ivars
    #      via the ORIGINAL Routes#ast/#simulator (no per-worker rebuild — a
    #      rebuild would have to read the frozen Route memos AND reuse several
    #      non-shareable class constants, which is fragile).
    #
    # We deliberately do NOT override ast/simulator: the original methods read
    # the cached ivars, which is exactly what workers need.
    def _install_journey_routes_patch
      return if @journey_routes_patched
      @journey_routes_patched = true
      _register_patch :journey_routes, "8.1"
      return unless defined?(::ActionDispatch::Journey::Routes)

      # Patch TransitionTable to drop its default-Proc @memos. Must run before
      # the simulator is warmed (in _warm_journey_routes!, called from
      # make_app_shareable! after the route precompute).
      if defined?(::ActionDispatch::Journey::GTG::TransitionTable)
        tt = ::ActionDispatch::Journey::GTG::TransitionTable
        tt.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def initialize
            @stdparam_states = {}
            @regexp_states   = {}
            @string_states   = {}
            @accepting       = {}
            @memos           = {}
          end
          def add_memo(idx, memo)
            (@memos[idx] ||= []) << memo
          end
        RUBY
      end

      # Make Routes#ast / #simulator tolerant of a FROZEN receiver. The shim
      # warms + caches these ivars on the live (unfrozen) graph before freezing,
      # but if the cache is missing on the frozen shared object (e.g. routes
      # were re-drawn after warming, or warming was skipped), the original
      # `@simulator ||= build` raise FrozenError in a worker Ractor. When frozen,
      # build and RETURN the value without memoizing — the build is read-only
      # over the frozen route nodes, so it's safe and stays worker-local.
      routes = ::ActionDispatch::Journey::Routes
      routes.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def ast
          return @ast if defined?(@ast) && @ast
          built = ::ActionDispatch::Journey::Nodes::Or.new(anchored_routes.map(&:ast))
          frozen? ? built : (@ast ||= built)
        end

        def simulator
          return @simulator if defined?(@simulator) && @simulator
          gtg = ::ActionDispatch::Journey::GTG::Builder.new(ast).transition_table
          built = ::ActionDispatch::Journey::GTG::Simulator.new(gtg)
          frozen? ? built : (@simulator ||= built)
        end
      RUBY

      # Path::Pattern memoizes several ivars via `||=` (@re, @offsets,
      # @required_names, @optional_names, @requirements_for_missing_keys_check).
      # On a frozen shared graph the `||=` assignment raises FrozenError in a
      # worker Ractor. Make them frozen-tolerant: return the cached value if
      # present, otherwise build and RETURN it without memoizing (the build is
      # read-only over the frozen ast/requirements). This keeps workers correct
      # even if warming skipped a pattern.
      if defined?(::ActionDispatch::Journey::Path::Pattern)
        ::ActionDispatch::Journey::Path::Pattern.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def required_names
            return @required_names if defined?(@required_names) && @required_names
            built = names - optional_names
            frozen? ? built : (@required_names ||= built)
          end

          def optional_names
            return @optional_names if defined?(@optional_names) && @optional_names
            built = spec.find_all(&:group?).flat_map { |g| g.find_all(&:symbol?) }.map(&:name).uniq
            frozen? ? built : (@optional_names ||= built)
          end

          def to_regexp
            return @re if defined?(@re) && @re
            built = regexp_visitor.new(@separators, @requirements).accept(spec)
            frozen? ? built : (@re ||= built)
          end

          def requirements_for_missing_keys_check
            return @requirements_for_missing_keys_check if defined?(@requirements_for_missing_keys_check) && @requirements_for_missing_keys_check
            built = requirements.transform_values { |regex| /\A#\{regex\}\Z/ }
            frozen? ? built : (@requirements_for_missing_keys_check ||= built)
          end

          def offsets
            return @offsets if defined?(@offsets) && @offsets
            built = begin
              offs = [0]
              spec.find_all(&:symbol?).each do |node|
                node = node.to_sym
                if @requirements.key?(node)
                  re = /#\{Regexp.union(@requirements[node])\}|/
                  offs.push((re.match("").length - 1) + offs.last)
                else
                  offs << offs.last
                end
              end
              offs
            end
            frozen? ? built : (@offsets ||= built)
          end
        RUBY
      end
    end

    # Journey's routing visitors are stored as instance singletons in class
    # constants (e.g. `ActionDispatch::Journey::Visitors::Each::INSTANCE`).
    # Worker Ractors read these constants while recognizing routes
    # (`Node#each` → `Each::INSTANCE.accept`, `Path::Pattern#match` →
    # `offsets` → `node.each`), and a non-frozen instance is NOT a shareable
    # object → `Ractor::IsolationError: can not access non-shareable objects in
    # constant ...::Each::INSTANCE by non-main Ractor`. The visitor instances
    # are stateless, so freezing them makes them shareable with no behavior
    # change. The same applies to the `DISPATCH_CACHE` Hashes the visitor
    # `accept`/`visit` dispatch through. These constants are NOT reachable
    # from the frozen app graph (Ractor.make_shareable never touches them), so
    # we must freeze them explicitly here (in main, before workers spawn).
    def _freeze_journey_visitors!
      return unless defined?(::ActionDispatch::Journey::Visitors)
      v = ::ActionDispatch::Journey::Visitors
      [[:Each, :INSTANCE], [:String, :INSTANCE], [:Dot, :INSTANCE]].each do |klass, const|
        mod = v.const_get(klass) rescue nil
        next unless mod && mod.const_defined?(const)
        inst = mod.const_get(const)
        inst.freeze if inst.respond_to?(:freeze) && !inst.frozen?
      end
      [[:Visitor, :DISPATCH_CACHE], [:FunctionalVisitor, :DISPATCH_CACHE]].each do |klass, const|
        mod = v.const_get(klass) rescue nil
        next unless mod && mod.const_defined?(const)
        cache = mod.const_get(const)
        cache.freeze if cache.respond_to?(:freeze) && !cache.frozen?
      end
      # GTG::Builder::DUMMY_END_NODE is a non-shareable instance referenced when
      # a worker Ractor rebuilds the route simulator (e.g. if the warmed
      # @simulator cache is missing on the frozen graph). Make it Ractor-shareable
      # (deep-freeze) so workers can read the constant without
      # Ractor::IsolationError. It is a stateless dummy node, so this is
      # behavior-preserving.
      if defined?(::ActionDispatch::Journey::GTG::Builder) &&
         ::ActionDispatch::Journey::GTG::Builder.const_defined?(:DUMMY_END_NODE)
        node = ::ActionDispatch::Journey::GTG::Builder.const_get(:DUMMY_END_NODE)
        Ractor.make_shareable(node) rescue nil
      end
    end

    # Pre-compute every Journey::Path::Pattern's lazy memoized ivars
    # (@required_names, @optional_names, @offsets, @re,
    # @requirements_for_missing_keys_check) on the LIVE (unfrozen) pattern,
    # before Ractor.make_shareable freezes the graph. `Path::Pattern#match`
    # (called on every request during route recognition) memoizes @offsets
    # via `@offsets ||= ...`; on a frozen pattern that write raises
    # FrozenError. By computing it now (and caching into the frozen object),
    # the worker reads the cached value and never writes. We deliberately do
    # NOT call the built-in `eager_load!`, which sets `@ast = nil` (the
    # @ast/@spec are still read by `requirements_anchored?` and must survive).
    def _warm_path_patterns!(routes)
      return unless routes.respond_to?(:routes)
      routes.routes.each do |r|
        p = r.respond_to?(:path) ? r.path : nil
        next unless p
        begin
          p.required_names
          p.optional_names
          p.send(:offsets)
          p.to_regexp
          p.requirements_for_missing_keys_check if p.respond_to?(:requirements_for_missing_keys_check)
        rescue
          # best-effort — a pattern we can't warm will fall back to its own
          # (non-frozen) copy if one exists; ignore unusual shapes.
        end
      end
    end

    # Warm + cache `@ast` / `@simulator` on the live Routes graph. Called from
    # make_app_shareable! AFTER the route precompute (which resets the routes)
    # and BEFORE Ractor.make_shareable freezes the graph. Must run in the main
    # Ractor. Idempotent (caches on the mutable object, then frozen in place).
    def _warm_journey_routes!
      return unless Ractor.main?
      _freeze_journey_visitors!
      _freeze_mime_negotiation!
      begin
        rs = ::Rails.application.routes rescue nil
        # Navigate to the ActionDispatch::Journey::Routes object — the one that
        # is frozen into the shared graph and read (via Router#simulator) on
        # every request. Rails wraps it in a RouteSet (and sometimes a
        # LazyRouteSet), neither of which defines #simulator, so calling
        # `rs.routes.simulator` would silently NoMethodError and leave @simulator
        # uncached — forcing worker Ractors to rebuild the simulator (and hit
        # Ractor::IsolationError on GTG constants). Descend through #routes until
        # we reach the Journey::Routes instance.
        routes = rs
        while routes.respond_to?(:routes) && !routes.is_a?(::ActionDispatch::Journey::Routes)
          nxt = routes.routes
          break if nxt.equal?(routes)
          routes = nxt
        end
        if routes.is_a?(::ActionDispatch::Journey::Routes)
          routes.ast
          routes.simulator
          _warm_path_patterns!(routes)
        end
      rescue => e
        # best-effort
      end
    end

    # ActionDispatch::Http::MimeNegotiation holds module-level constants
    # (e.g. RESCUABLE_MIME_FORMAT_ERRORS, an Array of exception classes) that
    # are referenced from the request path (params_readable? -> `rescue *
    # RESCUABLE_MIME_FORMAT_ERRORS`). These Arrays are non-frozen, hence
    # non-shareable, so a worker Ractor raises Ractor::IsolationError when it
    # reads them. Freeze the mutable constant-containing modules so workers can
    # read shareable copies. Regexp/Class constants are already shareable; only
    # the wrapping Array/Hash need freezing.
    def _freeze_mime_negotiation!
      return unless defined?(::ActionDispatch::Http::MimeNegotiation)
      mod = ::ActionDispatch::Http::MimeNegotiation
      mod.constants.each do |name|
        c = mod.const_get(name) rescue nil
        next unless c.is_a?(::Array) || c.is_a?(::Hash)
        next if c.frozen?
        c.freeze
        ::Ractor.make_shareable(c) rescue nil
      end
    rescue => e
      warn "[ractor-rails-shim] _freeze_mime_negotiation!: #{e.class}: #{e.message}"
    end

    # ActionDispatch::Http::URL reads the `tld_length` class variable
    # DIRECTLY (`@@tld_length`) in `normalize_host` and in the default-parameter
    # of `domain`/`subdomains`/`subdomain`. Class variables are not readable from
    # a non-main Ractor, so a worker raises
    # "Ractor::IsolationError: can not access class variables ... @@tld_length".
    # The shim routes the `mattr_accessor :tld_length` READER through IES, but the
    # literal `@@tld_length` references bypass that reader. Replace them with the
    # accessor method (which the shim's mattr_accessor rewrite makes
    # worker-safe). `domain`/`subdomains`/`subdomain` live in the `Url` module
    # mixed into ActionDispatch::Request, so patch that module too.
    def _install_action_dispatch_http_url_patch
      return if @action_dispatch_http_url_patched
      @action_dispatch_http_url_patched = true
      _register_patch :action_dispatch_http_url, "8.1"
      return unless defined?(::ActionDispatch::Http::URL)

      url = ::ActionDispatch::Http::URL
      # normalize_host is a module_function: build_host_url calls the
      # MODULE-LEVEL copy, so redefining the instance method alone leaves the
      # original (@@tld_length-reading) one in place. Patch the singleton
      # (module-level) method instead.
      url.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def normalize_host(_host, options)
          return _host unless named_host?(_host)
          tld_length = options[:tld_length] || tld_length()
          subdomain  = options.fetch :subdomain, true
          domain     = options[:domain]
          host = +""
          if subdomain == true
            return _host if domain.nil?
            host << extract_subdomains_from(_host, tld_length).join(".")
          elsif subdomain
            host << subdomain.to_param
          end
          host << "." unless host.empty?
          host << (domain || extract_domain_from(_host, tld_length))
          host
        end
      RUBY

      if defined?(::ActionDispatch::Http::URL::Url)
        ::ActionDispatch::Http::URL::Url.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def domain(tld_length = tld_length())
            ActionDispatch::Http::URL.extract_domain(host, tld_length)
          end
          def subdomains(tld_length = tld_length())
            ActionDispatch::Http::URL.extract_subdomains(host, tld_length)
          end
          def subdomain(tld_length = tld_length())
            ActionDispatch::Http::URL.extract_subdomain(host, tld_length)
          end
        RUBY
      end
    end
  end
end
