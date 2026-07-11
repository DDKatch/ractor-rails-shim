# frozen_string_literal: true

# Patch RubyGems `Gem.paths` (and thus `Gem.path`) to be Ractor-safe.
#
# In development, Propshaft serves assets on the fly and, on every request,
# runs its cache sweeper. That calls ActiveSupport::FileUpdateChecker which
# reads `Gem.path` -> `Gem.paths` -> the unshareable `@paths` class ivar on
# `Gem`. Reading that ivar from a worker Ractor raises Ractor::IsolationError
# ("can not get unshareable values ... @paths from Gem"). Any other dev code
# path that reads `Gem.path` from a worker hits the same wall.
#
# Fix: in the main Ractor `Gem.paths` behaves exactly as before (aliased to
# the original). In a worker Ractor we return a shareable snapshot of the
# main Ractor's gem paths, captured at prepare_for_ractors! time (after
# Bundler has configured gem paths, so the snapshot is complete).

module RactorRailsShim
  class << self
    # Installed at `install` (boot) time. Only redefines the reader; the
    # snapshot is filled in later by `snapshot_gem_paths!`.
    def install_rubygems
      return if @rubygems_patched
      @rubygems_patched = true
      _register_patch :rubygems, "all"
      return unless defined?(::Gem)
      patch_rubygems!
    end

    def patch_rubygems!
      return if @rubygems_method_patched
      @rubygems_method_patched = true
      gem = ::Gem
      unless gem.singleton_class.method_defined?(:__shim_original_gem_paths)
        gem.singleton_class.alias_method :__shim_original_gem_paths, :paths
      end
      # `def` (not `define_method`) so the method has no captured binding and
      # is callable from any Ractor. `Ractor.main?` + a shareable constant are
      # both Ractor-safe.
      gem.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def paths
          if Ractor.main?
            __shim_original_gem_paths
          else
            ::RactorRailsShim::GEM_PATHS_SNAPSHOT
          end
        end
      RUBY
    end

    # Called from prepare_for_ractors! (post-boot, main Ractor) so the
    # snapshot reflects Bundler-configured gem paths. Also called from
    # install as a safety net so the constant is never undefined.
    def snapshot_gem_paths!
      return unless defined?(::Gem)
      return if defined?(::RactorRailsShim::GEM_PATHS_SNAPSHOT)
      snap = ::Gem.paths
      begin
        Ractor.make_shareable(snap)
      rescue StandardError
        snap = Ractor.make_shareable(::Gem.path)
      end
      ::RactorRailsShim.const_set(:GEM_PATHS_SNAPSHOT, snap)
    end
  end
end
