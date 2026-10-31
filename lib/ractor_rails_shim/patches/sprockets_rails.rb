# frozen_string_literal: true

# Patch sprockets-rails' view asset accessors for worker Ractors.
#
# At boot, the railtie assigns onto the ActionView class
# (`helper.rb` VIEW_ACCESSORS class_attributes): `assets_environment` (the
# live Sprockets::Environment — fs/socket-backed, unshareable),
# `assets_manifest` (a Sprockets::Manifest holding mutable Hashes), and
# `precompiled_asset_checker` (a lambda closing over the un-shareable Rails
# application). Every `javascript_include_tag` / `stylesheet_link_tag` /
# `asset_path` in a worker-resolved view reads these → IsolationError.
#
# The runtime data is actually PLAIN: the Manifest's `assets` hash
# (logical path => digest path) and `files` hash (digest path => metadata)
# are pure String data — shareable when frozen. The patch:
#
#   * captures `assets` / `files` from the app's manifest at install into
#     frozen constants;
#   * defines a lightweight ManifestSnapshot POO that answers exactly the
#     `HelperAssetResolvers::Manifest` API (`#assets`, `#files`);
#   * overrides the four worker-relevant ActionView accessors:
#       - `assets_manifest` — worker => the frozen ManifestSnapshot;
#       - `precompiled_asset_checker` — worker => a fresh lambda checking
#         the captured assets hash;
#       - `assets_environment` — worker => nil (prod resolves via the
#         manifest; a manifest miss falls through to the :environment
#         resolver, which then fails fast with the upstream ::ArgumentError
#         instead of raising IsolationError);
#       - `check_precompiled_asset` — worker => the captured boolean.
#     Main keeps the live class-attribute values byte-for-byte.
#
# Asset COMPILATION stays in main/CI (deploy-time) — workers only resolve
# already-precompiled assets.

module RactorRailsShim
  # A frozen stand-in for Sprockets::Manifest answering the exact API the
  # sprockets-rails Manifest asset resolver touches.
  class SprocketsManifestSnapshot
    def initialize(assets, files)
      @assets = (begin
        ::Ractor.make_shareable(assets)
      rescue ::StandardError
        assets.freeze
      end)
      @files = (begin
        ::Ractor.make_shareable(files)
      rescue ::StandardError
        files.freeze
      end)
      freeze
    end

    attr_reader :assets
    attr_reader :files
  end

  class << self
    def _install_sprockets_rails_patch
      return if @sprockets_rails_patched
      @sprockets_rails_patched = true
      _register_patch :sprockets_rails, "8.1"
      return unless defined?(::Sprockets::Rails::Helper) && defined?(::ActionView::Base)

      _install_sprockets_view_accessors
    end

    private

    def _install_sprockets_view_accessors
      return unless ::Ractor.main?

      manifest = begin
        ::Rails.application.assets_manifest
      rescue ::StandardError
        nil
      end
      snapshot = nil
      if manifest && manifest.respond_to?(:assets)
        assets = ::Ractor.make_shareable(manifest.assets) rescue nil
        files = ::Ractor.make_shareable(manifest.files) rescue nil
        snapshot = SprocketsManifestSnapshot.new(assets || {}, files || {}) if assets
        _reassign_shareable_const(:SPROCKETS_MANIFEST_SNAPSHOT, snapshot) if snapshot
      end
      check = ::ActionView::Base.instance_variable_defined?(:@check_precompiled_asset) ?
        ::ActionView::Base.instance_variable_get(:@check_precompiled_asset) : nil
      _reassign_shareable_const(:SPROCKETS_CHECK_PRECOMPILED, ::Ractor.make_shareable(check || false))

      manifest_snapshot = snapshot ? "::RactorRailsShim::SPROCKETS_MANIFEST_SNAPSHOT" : "nil"
      ::ActionView::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_assets_manifest, :assets_manifest
        def assets_manifest
          if ::Ractor.main?
            _shim_original_assets_manifest
          else
            #{manifest_snapshot}
          end
        end

        alias_method :_shim_original_precompiled_asset_checker, :precompiled_asset_checker
        def precompiled_asset_checker
          if ::Ractor.main?
            _shim_original_precompiled_asset_checker
          else
            lambda do |logical_path|
              snap = begin
                ::RactorRailsShim::SPROCKETS_MANIFEST_SNAPSHOT
              rescue ::NameError
                nil
              end
              snap ? snap.assets.key?(logical_path.to_s) : false
            end
          end
        end

        alias_method :_shim_original_assets_environment, :assets_environment
        def assets_environment
          if ::Ractor.main?
            _shim_original_assets_environment
          else
            # The live Sprockets::Environment is unshareable; workers resolve
            # via the manifest (prod precompiles everything). A manifest miss
            # falls through to the :environment resolver, which fails fast
            # with the upstream ::ArgumentError.
            nil
          end
        end

        alias_method :_shim_original_check_precompiled_asset, :check_precompiled_asset
        def check_precompiled_asset
          if ::Ractor.main?
            _shim_original_check_precompiled_asset
          else
            ::RactorRailsShim::SPROCKETS_CHECK_PRECOMPILED
          end
        end

        # Workers must resolve via the manifest only: the :environment
        # strategy's resolver raises ::ArgumentError on construction when
        # assets_environment is nil (which is the worker case). The default
        # [:manifest, :environment] would break EVERY asset render in a
        # worker; prod-with-digests resolves everything from the manifest.
        alias_method :_shim_original_resolve_assets_with, :resolve_assets_with
        def resolve_assets_with
          if ::Ractor.main?
            _shim_original_resolve_assets_with
          else
            [:manifest]
          end
        end
      RUBY
    end
  end
end
