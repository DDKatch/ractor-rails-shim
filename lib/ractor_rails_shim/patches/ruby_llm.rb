# frozen_string_literal: true

# Patch ruby_llm's global singleton state for worker Ractors.
#
# ruby_llm is singleton-centric: a module-level Configuration, Logger, Models
# registry and provider registry, plus Mutex constants guarding lazy
# singletons. All are read at runtime by the chat/connection path. No
# mattr/class_attribute — the shim's macro rewrites don't apply.
#
#   1. `RubyLLM.config` — `@config ||= Configuration.new` module ivar; the
#      Configuration constructor reads the class-level `defaults` /
#      `option_keys` tables (`self.class.send(:defaults)`), so a worker's
#      first `RubyLLM.config` raises on BOTH the module ivar and the class
#      ivar. Fix: main captures the boot-configured option VALUES
#      (shareable subset) into a constant; workers build a fresh
#      `Configuration` (from the captured frozen class tables) and apply the
#      captured values. Unshareable option values (none expected — API keys
#      are Strings) fall back to defaults.
#   2. `RubyLLM.logger` — `@logger ||=` holds a Logger (IO + Mutex —
#      unshareable). Fix: per-Ractor logger via storage (same constructor
#      inputs from the per-Ractor config).
#   3. `RubyLLM.deprecator` — `@deprecator ||= ::RubyLLM::Support::Deprecator.new`.
#      Fix: per-Ractor via storage.
#   4. `RubyLLM::Provider.providers` / `model_registry_files` — boot-filled
#      module-ivar Hashes (slug Symbol => provider Class) read at runtime
#      for protocol resolution. Fix: shareable snapshot constant; workers
#      read the frozen copy (registration only happens at load/boot).
#   5. `RubyLLM::Models.instance` — `@instance || INSTANCE_LOCK.synchronize
#      { ... }`: constant Mutex read + class-ivar write off-main. Fix:
#      worker branch memoizes a fresh `Models` (its constructor reads the
#      JSON catalog — pure data work) via storage. Main keeps the original.
#   6. `RubyLLM::Models::Aliases.aliases` — same shape (LOAD_LOCK +
#      `@aliases ||=`). Fix: capture main's aliases table (pure String/Symbol
#      JSON data — shareable) into a constant; workers read it; main keeps
#      the original memo (`reload` stays main-only).
#   7. `RubyLLM::Support::Instrumentation` — `@subscribers` (frozen Array of
#      subscriber Procs/objects, main-created) + `@mutex` read per
#      `instrument` call (every LLM request). Fix: worker branch reads the
#      subscriber list from per-Ractor storage (empty => plain dispatch, a
#      no-op tracing stack); main keeps the originals.
#   8. `RubyLLM::Accounting::Usage.ledger` — the Rails usage ledger wraps
#      ActiveRecord and can never cross the boundary. Fix: worker reads nil
#      (accounting entries are simply not persisted from workers); writer
#      unchanged (boot only).

module RactorRailsShim
  class << self
    def _install_ruby_llm_patch
      return if @ruby_llm_patched
      @ruby_llm_patched = true
      _register_patch :ruby_llm, "8.1"
      return unless defined?(::RubyLLM)

      _install_ruby_llm_config
      _install_ruby_llm_logger_deprecator
      _install_ruby_llm_provider_registry
      _install_ruby_llm_models_instance
      _install_ruby_llm_aliases
      _install_ruby_llm_instrumentation
      _install_ruby_llm_usage_ledger
    end

    private

    # Snapshot the class-level tables + boot-configured option values.
    def _install_ruby_llm_config
      if ::Ractor.main?
        config = ::RubyLLM.config
        values = {}
        keys = ::RubyLLM::Configuration.options
        keys.each do |key|
          value = config.public_send(key) rescue nil
          next if value.nil?
          begin
            values[key] = ::Ractor.make_shareable(value)
          rescue ::StandardError
            nil
          end
        end
        _reassign_shareable_const(:RUBY_LLM_CONFIG_VALUES, ::Ractor.make_shareable(values))
        _reassign_shareable_const(:RUBY_LLM_OPTION_KEYS, ::Ractor.make_shareable(keys.freeze))
        defaults = ::RubyLLM::Configuration.instance_variable_get(:@defaults)
        _reassign_shareable_const(
          :RUBY_LLM_OPTION_DEFAULTS,
          ::Ractor.make_shareable(defaults.is_a?(::Hash) ? defaults.dup.freeze : {}.freeze)
        )
      end

      ::RubyLLM::Configuration.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def option_keys
          if ::Ractor.main?
            @option_keys ||= []
          else
            ::RactorRailsShim::RUBY_LLM_OPTION_KEYS
          end
        end

        def defaults
          if ::Ractor.main?
            @defaults ||= {}
          else
            ::RactorRailsShim::RUBY_LLM_OPTION_DEFAULTS
          end
        end
      RUBY

      ::RubyLLM.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def config
          if ::Ractor.main?
            @config ||= Configuration.new
          else
            key = :ractor_rails_shim_ruby_llm_config
            ::RactorRailsShim.storage[key] ||= ::RactorRailsShim._worker_ruby_llm_config
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    # Fresh Configuration for a worker: class tables come from the captured
    # frozen constants; the app's boot-configured values are applied after.
    def _worker_ruby_llm_config
      config = ::RubyLLM::Configuration.new
      values = begin
        ::RactorRailsShim::RUBY_LLM_CONFIG_VALUES
      rescue ::NameError
        nil
      end
      values&.each do |key, value|
        config.public_send(:"#{key}=", value)
      end
      config
    end

    def _install_ruby_llm_logger_deprecator
      ::RubyLLM.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_logger, :logger
        def logger
          if ::Ractor.main?
            _shim_original_logger
          else
            key = :ractor_rails_shim_ruby_llm_logger
            ::::RactorRailsShim.storage[key] ||= config.logger || ::Logger.new(
              config.log_file,
              progname: 'RubyLLM',
              level: config.log_level
            )
            ::RactorRailsShim.storage[key]
          end
        end

        def deprecator
          if ::Ractor.main?
            @deprecator ||= ::RubyLLM::Support::Deprecator.new
          else
            key = :ractor_rails_shim_ruby_llm_deprecator
            ::::RactorRailsShim.storage[key] ||= ::RubyLLM::Support::Deprecator.new
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_ruby_llm_provider_registry
      return unless defined?(::RubyLLM::Provider)
      if ::Ractor.main?
        providers = ::RubyLLM::Provider.providers
        files = ::RubyLLM::Provider.model_registry_files
        _reassign_shareable_const(:RUBY_LLM_PROVIDERS, ::Ractor.make_shareable(providers.dup.freeze)) rescue nil
        _reassign_shareable_const(:RUBY_LLM_REGISTRY_FILES, ::Ractor.make_shareable(files.dup.freeze)) rescue nil
      end
      ::RubyLLM::Provider.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def providers
          if ::Ractor.main?
            @providers ||= {}
          else
            snapshot = begin
              ::RactorRailsShim::RUBY_LLM_PROVIDERS
            rescue ::NameError
              nil
            end
            snapshot || {}
          end
        end

        def model_registry_files
          if ::Ractor.main?
            @model_registry_files ||= {}
          else
            snapshot = begin
              ::RactorRailsShim::RUBY_LLM_REGISTRY_FILES
            rescue ::NameError
              nil
            end
            snapshot || {}
          end
        end
      RUBY
    end

    def _install_ruby_llm_models_instance
      return unless defined?(::RubyLLM::Models)
      ::RubyLLM::Models.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def instance
          if ::Ractor.main?
            @instance || INSTANCE_LOCK.synchronize { @instance ||= new }
          else
            key = :ractor_rails_shim_ruby_llm_models
            ::RactorRailsShim.storage[key] ||= new
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_ruby_llm_aliases
      return unless defined?(::RubyLLM::Models::Aliases)
      if ::Ractor.main?
        aliases = ::RubyLLM::Models::Aliases.instance_variable_get(:@aliases) ||
          ::RubyLLM::Models::Aliases.load_aliases
        _reassign_shareable_const(:RUBY_LLM_ALIASES, ::Ractor.make_shareable(aliases)) rescue nil
      end
      ::RubyLLM::Models::Aliases.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def aliases
          if ::Ractor.main?
            @aliases || LOAD_LOCK.synchronize { @aliases ||= load_aliases }
          else
            snapshot = begin
              ::RactorRailsShim::RUBY_LLM_ALIASES
            rescue ::NameError
              nil
            end
            snapshot || {}
          end
        end
      RUBY
    end

    def _install_ruby_llm_instrumentation
      return unless defined?(::RubyLLM::Support::Instrumentation)
      ::RubyLLM::Support::Instrumentation.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        module_function

        # Worker branch reads the (empty) per-Ractor subscriber list instead
        # of the module ivar holding main-created subscriber objects.
        def subscribers
          if ::Ractor.main?
            @subscribers
          else
            key = :ractor_rails_shim_ruby_llm_subscribers
            ::RactorRailsShim.storage[key] ||= [].freeze
            ::RactorRailsShim.storage[key]
          end
        end

        def instrument(name, payload = nil, config: nil, **attributes, &block)
          payload ||= {}
          payload = payload.merge(attributes) unless attributes.empty?
          workflow_context = current_workflow
          payload = payload.merge(workflow_context) if workflow_context
          instrumenter = (config || RubyLLM.config).instrumenter
          subscribers = ::Ractor.main? ? @subscribers : subscribers
          return dispatch(instrumenter, name, payload, &block) if subscribers.empty?

          dispatch = -> { dispatch(instrumenter, name, payload, &block) }
          subscribers.reverse_each do |subscriber|
            inner = dispatch
            dispatch = -> { subscriber.instrument(name, payload, &inner) }
          end
          dispatch.call
        end

        def capture_context
          subs = ::Ractor.main? ? @subscribers : subscribers
          subs.filter_map do |subscriber|
            [subscriber, subscriber.capture_context] if subscriber.respond_to?(:capture_context)
          end
        end
      RUBY
    end

    def _install_ruby_llm_usage_ledger
      return unless defined?(::RubyLLM::Accounting::Usage)
      ::RubyLLM::Accounting::Usage.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def ledger
          if ::Ractor.main?
            @ledger
          else
            # AR-backed ledger can never cross the Ractor boundary; workers
            # skip accounting entries instead of raising.
            nil
          end
        end
      RUBY
    end
  end
end
