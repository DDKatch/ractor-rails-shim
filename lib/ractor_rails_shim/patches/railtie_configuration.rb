# frozen_string_literal: true

# `RactorRailsShim::Patches::RailtieConfiguration` — the role object that
# owns the Rails::Railtie::Configuration class-variable patch.
#
# Background: Rails 8.1 stores the method_missing-backed option hash in the
# CLASS VARIABLE @@options. Ruby 4.0 forbids ANY class-variable access from
# a non-main Ractor (Ractor::IsolationError: can not access class variables
# from non-main Ractors), so a worker-side read of a method_missing-backed
# config option — e.g. `config.x` — dies in a worker.
#
# Technique note: the override CANNOT be a prepended module. Ruby forbids
# class-variable access from a prepended module whose "owner" differs from
# the class ("class variable @@options ... is overtaken by <module>"), and
# even a non-accessing worker branch would be compiled into the module. The
# override is therefore installed with `class_eval` on the class itself
# (cvar owner == the class, legal), delegating to aliased originals.
#
# Semantics:
#   - MAIN Ractor: the original methods run unchanged — 100% upstream
#     behavior, including the (incidental) global sharing of the @@options
#     hash across all Railtie::Configuration instances and subclasses.
#   - Workers: reads resolve through (1) a frozen SNAPSHOT of the main-side
#     @@options, taken in ShareabilityTraversal.precompute_lazy_ivars
#     (post-boot, pre-freeze) and stored as the frozen constant
#     RRS_FROZEN_OPTIONS on the class — constants are shareable, the class
#     variable is not — then (2) a per-Ractor IES overlay keyed by the
#     config object's identity for worker-local writes. The worker branch
#     never touches the class variable.
#   - Worker-local writes shadow the snapshot for that worker only
#     (matching the shim's freeze philosophy: worker state is
#     worker-local). Mainstream code reads method_missing-backed options
#     from the main Ractor (boot, initializers).
#
# This object owns the idempotency flag (`@installed`). The facade method
# `_install_railtie_configuration_patch` (patches/core.rb) delegates here.

module RactorRailsShim
  module Patches
    module RailtieConfiguration
      @installed = false
      @mutex = Mutex.new

      # Install the Railtie::Configuration override. Idempotent — the
      # `@installed` flag lives on this object. Returns true once installed
      # (and on subsequent no-op calls).
      def self.install
        @mutex.synchronize do
          return true if @installed
          return true unless defined?(::Rails::Railtie::Configuration)
          return true if ::Rails::Railtie::Configuration.method_defined?(:rrs_original_respond_to)

          # class_eval (NOT prepend): the worker branch must be compiled in
          # a context that MAY legally name @@options, and Ruby forbids
          # cvar access from prepended modules ("overtaken"). Methods
          # defined via class_eval on the class itself own the class's
          # cvars, so the main-side delegation stays legal.
          ::Rails::Railtie::Configuration.class_eval <<~RUBY, __FILE__, __LINE__ + 1
            alias_method :rrs_original_respond_to, :respond_to?
            def respond_to?(name, include_private = false)
              if defined?(::Ractor) && ::Ractor.current != ::Ractor.main
                self.class.method_defined?(name.to_sym) ||
                  (include_private && self.class.private_method_defined?(name.to_sym)) ||
                  rrs_worker_config_options.key?(name.to_sym) ||
                  rrs_frozen_config_options.key?(name.to_sym)
              else
                rrs_original_respond_to(name, include_private)
              end
            end

            alias_method :rrs_original_method_missing, :method_missing
            def method_missing(name, *args, &blk)
              unless defined?(::Ractor) && ::Ractor.current != ::Ractor.main
                return rrs_original_method_missing(name, *args, &blk)
              end

              # The worker may not touch the class variable, so reads go
              # through the frozen snapshot (main-boot options) with a
              # per-Ractor IES overlay (worker-local writes), and unknown
              # names raise instead of falling back to the original
              # (whose @@options access is forbidden here).
              if name.end_with?("=")
                key = name[0..-2].to_sym
                # Mirror upstream's actual_method? guard, worker-side:
                # reject assignment to a real configuration method unless
                # an option of that name already exists.
                if respond_to?(key) && !rrs_worker_config_options.key?(key) && !rrs_frozen_config_options.key?(key)
                  raise NoMethodError.new("Cannot assign to `\#{key}`, it is a configuration method")
                end
                rrs_worker_config_options[key] = args.first
              elsif rrs_worker_config_options.key?(name)
                rrs_worker_config_options[name]
              elsif rrs_frozen_config_options.key?(name)
                rrs_frozen_config_options[name]
              else
                raise NoMethodError.new("undefined method '\#{name}' for \#{inspect}")
              end
            end

            private

            # Per-Ractor write overlay for this configuration object: an IES
            # slot namespaced by object_id, so multiple frozen configuration
            # objects don't collide and each worker Ractor gets its own.
            def rrs_worker_config_options
              slot = ::RactorRailsShim.storage[:rrs_railtie_config] ||= {}
              slot[object_id] ||= {}
            end

            # Frozen main-side option snapshot. Populated post-boot by
            # ShareabilityTraversal (precompute_lazy_ivars); absent when
            # the shim never ran its freeze in this process.
            def rrs_frozen_config_options
              if ::Rails::Railtie::Configuration.const_defined?(:RRS_FROZEN_OPTIONS)
                ::Rails::Railtie::Configuration.const_get(:RRS_FROZEN_OPTIONS)
              else
                {}
              end
            end
          RUBY

          @installed = true
        end
        true
      end

      def self.installed?
        @installed
      end
    end
  end
end
