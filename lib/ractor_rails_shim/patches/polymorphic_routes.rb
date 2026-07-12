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

      # The module-level `polymorphic_path` / `polymorphic_url` (called by
      # `form_with` when it infers the URL from a model) invoke
      # `mapping.call` directly. A custom `resolve` mapping Proc is built in
      # the main Ractor and is un-shareable, so calling it from a worker
      # Ractor raises "defined with an un-shareable Proc in a different
      # Ractor". Rescue that and fall through to the (worker-safe)
      # HelperMethodBuilder path, which derives the route from the record's
      # model name — the same fallback the original code uses when no mapping
      # is registered at all.
      pm = ::ActionDispatch::Routing::PolymorphicRoutes
      pm.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def polymorphic_path(record_or_hash_or_array, options = {})
          if ::Hash === record_or_hash_or_array
            options = record_or_hash_or_array.merge(options)
            record  = options.delete :id
            return polymorphic_path record, options
          end

          if mapping = (polymorphic_mapping(record_or_hash_or_array) rescue nil)
            begin
              return mapping.call(self, [record_or_hash_or_array, options], true)
            rescue ::Ractor::Error
            end
          end

          opts   = options.dup
          action = opts.delete :action
          type   = :path

          HelperMethodBuilder.polymorphic_method self,
                                                 record_or_hash_or_array,
                                                 action,
                                                 type,
                                                 opts
        end

        def polymorphic_url(record_or_hash_or_array, options = {})
          if ::Hash === record_or_hash_or_array
            options = record_or_hash_or_array.merge(options)
            record  = options.delete :id
            return polymorphic_url record, options
          end

          if mapping = (polymorphic_mapping(record_or_hash_or_array) rescue nil)
            begin
              return mapping.call(self, [record_or_hash_or_array, options], false)
            rescue ::Ractor::Error
            end
          end

          opts   = options.dup
          action = opts.delete :action
          type   = opts.delete(:routing_type) || :url

          HelperMethodBuilder.polymorphic_method self,
                                                 record_or_hash_or_array,
                                                 action,
                                                 type,
                                                 opts
        end
      RUBY
    end
  end
end
