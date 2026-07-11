# frozen_string_literal: true

# Patch ActionDispatch::Routing::PolymorphicRoutes::HelperMethodBuilder.
#
# Two Ractor-safety problems live here:
#
# 1. The class body populates a `CACHE` constant with HelperMethodBuilder
#    instances that hold un-shareable lambdas (e.g. `->(name) { name.route_key }`).
#    Because the constant lives on the shared class, a worker Ractor that reads
#    `CACHE[:path][nil]` touches a main-Ractor-owned object and raises
#    "defined with an un-shareable Proc in a different Ractor". Fix: stop reading
#    `CACHE` — build a fresh builder in the *calling* Ractor on every lookup.
#
# 2. `HelperMethodBuilder#handle_model_call` calls `polymorphic_mapping`, which
#    reads `target._routes.polymorphic_mappings` — a shared hash of main-built
#    Procs. Reading it from a worker raises the same error. Fix: skip the shared
#    mapping and build the route from the (worker-owned) builder's own logic.

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
          build action, type
        end

        def url
          build nil, "url"
        end

        def path
          build nil, "path"
        end
      RUBY
      hmb.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def handle_model_call(target, record)
          if mapping = polymorphic_mapping(target, record) rescue nil
            mapping.call(target, [record], suffix == "path")
          else
            method, args = handle_model(record)
            target.public_send(method, *args)
          end
        end
      RUBY
    end
  end
end
