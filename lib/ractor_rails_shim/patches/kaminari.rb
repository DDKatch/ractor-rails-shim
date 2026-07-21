# frozen_string_literal: true

# Patch Kaminari::config to not read the @_config class ivar from a worker
# Ractor.
#
# Blocker 2:
#   Kaminari.config reads @_config directly at kaminari/config.rb:14:
#     def self.config; @_config ||= Kaminari::Configuration.new end
#   Not mattr_accessor-backed, so the shim's mattr rewrite doesn't catch it.
#   Reading @_config from a worker raises
#   Ractor::IsolationError (@_config from Kaminari).
#
# Fix: Targeted patch like the Warden hooks patch. Route Kaminari.config
# through IES; in the main ractor return the existing @_config; in workers
# return a shareable fallback (the config object made shareable via
# Ractor.make_shareable). The config is a simple value object (integers,
# symbols, nils) — all shareable when frozen.

module RactorRailsShim
  class << self
    def _install_kaminari_config_patch
      return if @kaminari_patched
      @kaminari_patched = true
      _register_patch :kaminari_config, "8.1"
      return unless defined?(::Kaminari)

      # In the main ractor, capture the config object and make it shareable.
      shareable_config = nil
      if Ractor.main?
        begin
          cfg = ::Kaminari.instance_variable_get(:@_config) rescue nil
          if cfg
            begin
              Ractor.make_shareable(cfg)
              shareable_config = cfg
            rescue => e
              # If the config can't be made shareable (unlikely — it's all
              # integers/symbols/nil), build a fresh one with defaults.
              shareable_config = Ractor.make_shareable(::Kaminari::Config.new)
            end
          else
            shareable_config = Ractor.make_shareable(::Kaminari::Config.new)
          end
        rescue => e
          # Best-effort
        end
      end
      shareable_config ||= Ractor.make_shareable(::Kaminari::Config.new) rescue nil

      # Store the shareable config as a constant so workers can read it.
      if shareable_config
        verbose, $VERBOSE = $VERBOSE, nil
        begin
          const_set(:KAMINARI_SHAREABLE_CONFIG, shareable_config)
        ensure
          $VERBOSE = verbose
        end
      end

      k_key = :ractor_rails_shim_kaminari_config
      k_key_str = k_key.inspect
      ::Kaminari.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def config
          v = ActiveSupport::IsolatedExecutionState[#{k_key_str}]
          return v if ActiveSupport::IsolatedExecutionState.key?(#{k_key_str})
          if Ractor.main? && instance_variable_defined?(:@_config)
            @_config
          else
            RactorRailsShim::KAMINARI_SHAREABLE_CONFIG
          end
        end

        def config=(val)
          ActiveSupport::IsolatedExecutionState[#{k_key_str}] = val
        end
      RUBY

      # Register so the shareable fallback builder knows about it.
      CLASS_ATTRIBUTES << ["Kaminari", :config, k_key, nil] if shareable_config
    end
  end
end
