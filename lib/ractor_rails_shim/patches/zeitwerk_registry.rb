# frozen_string_literal: true

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

module RactorRailsShim
  class << self
    def install_zeitwerk_registry
      return if @zeitwerk_patched
      @zeitwerk_patched = true
      _register_patch :zeitwerk_registry, "8.1"
      if defined?(::Zeitwerk::Registry)
        patch_zeitwerk_registry!
      else
        # Defer until Zeitwerk loads. A TracePoint(:class) fires when
        # `module Registry` opens. One-shot.
        #
        # Two flags guard different things (mirrors `rails_module.rb`):
        #   @zeitwerk_patched          — `install_zeitwerk_registry` ran
        #                                 (so we don't arm a second TracePoint).
        #   @zeitwerk_registry_patched — the actual patch was applied (checked
        #                                 again inside the TracePoint block and
        #                                 in `patch_zeitwerk_registry!`).
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
  end
end
