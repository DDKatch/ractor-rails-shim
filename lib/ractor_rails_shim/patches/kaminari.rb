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
            rescue StandardError => e
              # If the config can't be made shareable (unlikely — it's all
              # integers/symbols/nil), build a fresh one with defaults.
              shareable_config = Ractor.make_shareable(::Kaminari::Config.new)
            end
          else
            shareable_config = Ractor.make_shareable(::Kaminari::Config.new)
          end
        rescue StandardError => e
          # Best-effort
        end
      end
      shareable_config ||= Ractor.make_shareable(::Kaminari::Config.new) rescue nil

      # Store the shareable config as a constant so workers can read it.
      if shareable_config
        _reassign_shareable_const(:KAMINARI_SHAREABLE_CONFIG, shareable_config)
      end

      k_key = :ractor_rails_shim_kaminari_config
      k_key_str = k_key.inspect
      ::Kaminari.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def config
          v = RactorRailsShim.storage[#{k_key_str}]
          return v if RactorRailsShim.storage.key?(#{k_key_str})
          if Ractor.main? && instance_variable_defined?(:@_config)
            @_config
          else
            RactorRailsShim::KAMINARI_SHAREABLE_CONFIG
          end
        end

        def config=(val)
          RactorRailsShim.storage[#{k_key_str}] = val
        end
      RUBY

      # Register so the shareable fallback builder knows about it.
      CLASS_ATTRIBUTES << ["Kaminari", :config, k_key, nil] if shareable_config

      # Patch Kaminari's `page` class method to avoid the `extending` block
      # (a Proc compiled in the main Ractor). Kaminari defines `page` via eval
      # with `.extending { include Kaminari::ActiveRecordRelationMethods;
      # include Kaminari::PageScopeMethods }` — a block that captures the main
      # Ractor's binding. Calling it from a worker raises "defined with an
      # un-shareable Proc in a different Ractor". Fix: redefine `page` to pass
      # the modules as arguments to `extending` (shareable constants, no block).
      # The delegate classes already include these modules from main's
      # _share_model_classes!, so the extending is redundant in workers but
      # harmless (it just re-adds already-included modules).
      _install_kaminari_page_method_patch
    end

    def _install_kaminari_page_method_patch
      return if @kaminari_page_patched
      @kaminari_page_patched = true
      _register_patch :kaminari_page_method, "8.1"
      return unless defined?(::Kaminari)
      return unless defined?(::ActiveRecord::Base)

      page_method_name = (::Kaminari.config.page_method_name rescue :page).to_s
      return if page_method_name.empty?

      # Override on ActiveRecord::Base singleton class (Kaminari defines it
      # here via eval in the included block of ActiveRecordModelExtension).
      ::ActiveRecord::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{page_method_name}(num = nil)
          per_page = max_per_page && (default_per_page > max_per_page) ? max_per_page : default_per_page
          limit(per_page).offset(per_page * ((num = num.to_i - 1) < 0 ? 0 : num)).extending(
            ::Kaminari::ActiveRecordRelationMethods,
            ::Kaminari::PageScopeMethods
          )
        end
      RUBY
    end
  end
end
