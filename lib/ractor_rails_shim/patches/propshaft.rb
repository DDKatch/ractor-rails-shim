# frozen_string_literal: true

# Patch for Propshaft (the default Rails 8 asset pipeline). The Assembly and
# LoadPath memoize their derived values in lazy instance ivars via `||=`:
#
#   Propshaft::Assembly#load_path   -> @load_path ||= Propshaft::LoadPath.new(...)
#   Propshaft::Assembly#compilers   -> @compilers ||= Propshaft::Compilers.new(...)
#   Propshaft::LoadPath#assets_by_path        -> @cached_assets_by_path ||= ...
#   Propshaft::LoadPath#asset_paths_by_type   -> (@cached_... ||= Hash.new)[ct] ||= ...
#   Propshaft::LoadPath#asset_paths_by_glob   -> (@cached_... ||= Hash.new)[g]  ||= ...
#
# The Assembly/LoadPath live inside the frozen, shared Rails.application graph
# (set by the propshaft railtie at boot, then deep-frozen by
# make_app_shareable!). A worker Ractor calling `||=` to populate these ivars
# raises FrozenError because the host object is frozen.
#
# Fix: warm every Assembly/LoadPath lazy ivar in MAIN (before freezing) so the
# `||=` short-circuits in workers (the ivar is already set → truthy → no
# assignment). The two `asset_paths_by_*` methods additionally perform a
# *write* to their inner Hash even when the key already exists (`h[k] ||= v`
# is `h[k] = h[k] || v`, which assigns to a frozen Hash). Route those two
# through IsolatedExecutionState (each Ractor builds its own cache from
# `assets`, which is already warmed read-only).

module RactorRailsShim
  class << self
    def _install_propshaft_patch
      return if @propshaft_patched
      @propshaft_patched = true
      _register_patch :propshaft, "1.3"
      return unless defined?(::Propshaft::LoadPath)

      lp = ::Propshaft::LoadPath
      lp.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def asset_paths_by_type(content_type)
          cache = (ActiveSupport::IsolatedExecutionState[:"ractor_rails_shim_propshaft_type_\#{object_id}"] ||= {})
          if cache.key?(content_type)
            cache[content_type]
          else
            cache[content_type] = extract_logical_paths_from(assets.select { |a| a.content_type == ::Mime::EXTENSION_LOOKUP[content_type] })
          end
        end

        def asset_paths_by_glob(glob)
          cache = (ActiveSupport::IsolatedExecutionState[:"ractor_rails_shim_propshaft_glob_\#{object_id}"] ||= {})
          if cache.key?(glob)
            cache[glob]
          else
            cache[glob] = extract_logical_paths_from(assets.select { |a| a.path.fnmatch?(glob) })
          end
        end
      RUBY

      if lp.method_defined?(:asset_paths_by_path)
        lp.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def asset_paths_by_path(path)
            cache = (ActiveSupport::IsolatedExecutionState[:"ractor_rails_shim_propshaft_path_\#{object_id}"] ||= {})
            if cache.key?(path)
              cache[path]
            else
              cache[path] = extract_logical_paths_from(assets.select { |a| a.path.fnmatch?(path) })
            end
          end
        RUBY
      end
    end

    # Warm every Propshaft Assembly/LoadPath lazy ivar in MAIN (before the app
    # is frozen). Warmed ivars are truthy, so the `||=` memoization in workers
    # short-circuits instead of attempting to assign onto a frozen object.
    # Assets::by_path is itself memoized; warming `assets` populates it so
    # workers only read the frozen cache.
    def _precompute_propshaft!(app)
      return unless Ractor.main?
      assets = app.assets rescue nil
      return unless assets
      assets.load_path rescue nil
      assets.compilers rescue nil
      assets.resolver rescue nil
      assets.prefix rescue nil
      assets.processor rescue nil
      # Build the asset map (LoadPath#assets -> assets_by_path) so the inner
      # cache is populated and frozen before workers read it. Then warm each
      # Asset's lazy ivars (@content_type, @digest) in MAIN — they are memoized
      # via `||=` and the Asset objects live inside the frozen, shared app
      # graph, so a worker reading them would raise FrozenError. Warming here
      # (while still mutable) lets the `||=` short-circuit in workers.
      assets.load_path.assets.each do |asset|
        asset.content_type rescue nil
        asset.digest rescue nil
      end
      # Warm the resolver manifest cache. Propshaft::Resolver::Static#manifest
      # memoizes `@manifest ||= Propshaft::Manifest.from_path(...)`; the
      # resolver is frozen in the shared graph, so without warming, a worker
      # rendering a `stylesheet_link_tag` (or reading asset integrity) for a
      # PRECOMPILED manifest raises FrozenError ("can't modify frozen
      # Propshaft::Resolver::Static"). `#manifest` is private — invoke via
      # send to trigger the `||=` in MAIN (while still mutable) so workers only
      # read the frozen, cached value.
      resolver = assets.resolver rescue nil
      if resolver.respond_to?(:manifest, true)
        begin
          resolver.send(:manifest)
        rescue
          nil
        end
      end
    end
  end
end
