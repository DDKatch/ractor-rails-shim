# frozen_string_literal: true

# Ractor-safe URL helper generation.
#
# Rails builds every URL helper method (`posts_path`, `_routes`,
# `_generate_paths_by_default`, the `direct`/`resolve` helpers, …) with
# `define_method(&block)` / `redefine_method(&block)`, and uses the
# `RouteSet::PATH` / `RouteSet::UNKNOWN` lambdas as the `url_strategy` callable.
# All of those are Procs created in the main Ractor; calling them from a worker
# Ractor that shares the frozen app graph raises
# "defined with an un-shareable Proc in a different Ractor".
#
# Fixes (must run BEFORE routes are drawn, i.e. before
# `Rails.application.initialize!`):
#
#   * Replace `RouteSet::PATH` / `RouteSet::UNKNOWN` with shareable `Method`
#     objects (a `Method` is Ractor-shareable, unlike a lambda).
#   * Regenerate the named helpers and `_routes` / `_generate_paths_by_default`
#     as compiled `def` methods (shareable) instead of `define_method` blocks.
#     The per-helper `CustomUrlHelper`/`UrlHelper` object is stored on the
#     module as a constant and looked up inside the `def`.
#
# NOTE: all `module_eval` bodies are built with string *concatenation* (no
# `#{}` inside string literals) so they are not interpolated at patch-apply
# time. Method-level `#{}` in symbol literals (e.g. `:"RRS_HELPER_#{name}"`)
# is ordinary Ruby interpolation evaluated when the generated method runs.

module RactorRailsShim
  class << self
    def install_route_helpers_patch
      return if @route_helpers_patched
      @route_helpers_patched = true
      _register_patch :route_helpers, "8.1"
      return unless defined?(::ActionDispatch::Routing::RouteSet)

      rs = ::ActionDispatch::Routing::RouteSet

      # 1. Replace the PATH / UNKNOWN lambdas with shareable Method objects.
      begin
        rs.send(:remove_const, :PATH) if rs.const_defined?(:PATH, false)
      rescue
      end
      rs.const_set(:PATH, ::ActionDispatch::Http::URL.method(:path_for)) rescue nil
      begin
        rs.send(:remove_const, :UNKNOWN) if rs.const_defined?(:UNKNOWN, false)
      rescue
      end
      rs.const_set(:UNKNOWN, ::ActionDispatch::Http::URL.method(:url_for)) rescue nil

      # 2. Named route helpers -> compiled `def` (regular `resources` routes).
      rs.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def define_url_helper(mod, name, helper, url_strategy)
          const_name = :"RRS_HELPER_\#{name}"
          mod.const_set(const_name, helper)
          strategy = url_strategy.equal?(PATH) ? :PATH : :UNKNOWN
          body = "def " + name.to_s + "(*args)\\n" \
                 "  last = args.last\\n" \
                 "  options = case last\\n" \
                 "    when Hash then args.pop\\n" \
                 "    when ActionController::Parameters then args.pop.to_h\\n" \
                 "  end\\n" \
                 "  ::ActionDispatch::Routing::RouteSet.const_get(" + const_name.inspect + ").call(self, " + name.inspect + ", args, options, ::ActionDispatch::Routing::RouteSet.const_get(" + strategy.inspect + "))\\n" \
                 "end"
          mod.module_eval(body, __FILE__, __LINE__ + 1)
        end
      RUBY

      # 3. `direct` / `resolve` helpers -> compiled `def`.
      if defined?(::ActionDispatch::Routing::RouteSet::NamedRouteCollection)
        ::ActionDispatch::Routing::RouteSet::NamedRouteCollection.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def add_url_helper(name, defaults, &block)
            helper = CustomUrlHelper.new(name, defaults, &block)
            path_name = :"\#{name}_path"
            url_name  = :"\#{name}_url"
            @path_helpers_module.const_set(:"RRS_HELPER_\#{path_name}", helper)
            @url_helpers_module.const_set(:"RRS_HELPER_\#{url_name}", helper)
            pbody = "def " + path_name.to_s + "(*args)\\n  const_get(:\\\"RRS_HELPER_" + path_name.to_s + "\\\").call(self, args, true)\\nend"
            ubody = "def " + url_name.to_s + "(*args)\\n  const_get(:\\\"RRS_HELPER_" + url_name.to_s + "\\\").call(self, args, false)\\nend"
            @path_helpers_module.module_eval(pbody, __FILE__, __LINE__ + 1)
            @url_helpers_module.module_eval(ubody, __FILE__, __LINE__ + 1)
            @path_helpers << path_name
            @url_helpers  << url_name
            self
          end
        RUBY
      end

      # 4. `_routes` / `_generate_paths_by_default` -> compiled `def`.
      rs.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_rrs_orig_generate_url_helpers, :generate_url_helpers
        def generate_url_helpers(supports_path)
          routes = self
          mod = _rrs_orig_generate_url_helpers(supports_path)
          mod.module_eval("def _routes\n  @_routes || ::Rails.application.routes\nend", __FILE__, __LINE__ + 1)
          mod.module_eval("def _generate_paths_by_default\n  " + supports_path.inspect + "\nend", __FILE__, __LINE__ + 1)
          mod
        end
      RUBY
    end

    # The module-level singleton `_routes` (set via `redefine_singleton_method`
    # in the gem's `included` block) is still a `define_method` block. It is not
    # on the request hot-path, but make it shareable anyway. Called after the
    # module has been included into ActionView/ActionController (i.e. from
    # `prepare_for_ractors!`).
    def fix_url_helpers_singleton_routes
      return unless defined?(::Rails) && ::Rails.application
      return unless ::Rails.application.routes.respond_to?(:url_helpers)
      mod = ::Rails.application.routes.url_helpers
      return unless mod.respond_to?(:singleton_class)
      mod.singleton_class.class_eval do
        def _routes
          ::Rails.application.routes
        end
      end
    rescue
    end
  end
end
