# frozen_string_literal: true

# Patch ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder.
# Its `CACHE` constant (`{ path: {}, url: {} }`) is populated at class-load with
# HelperMethodBuilder instances that hold un-shareable lambdas (e.g.
# `->(name) { name.route_key }`). The resulting constant is non-shareable, so a
# worker Ractor that calls `HelperMethodBuilder.get` / `.url` / `.path` raises
# "can not access non-shareable objects in constant ... CACHE by non-main
# ractor". Route the cache through IsolatedExecutionState so each Ractor builds
# its own (deterministic, shareable-within-itself) builders.

module RactorRailsShim
  class << self
    def _install_polymorphic_routes_patch
      return if @polymorphic_routes_patched
      @polymorphic_routes_patched = true
      _register_patch :polymorphic_routes, "8.1"
      return unless defined?(::ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder)
      hmb = ::ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder
      hmb.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def get(action, type)
          type = type.to_sym
          cache[type][action] ||= build(action, type)
        end

        def url
          cache[:url][nil] ||= build(nil, "url")
        end

        def path
          cache[:path][nil] ||= build(nil, "path")
        end

        def cache
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_polymorphic_cache] ||= { path: {}, url: {} }
        end
      RUBY
    end
  end
end
