# frozen_string_literal: true

# Patches for ActiveSupport: Inflector::Inflections, ErrorReporter,
# I18n::Config, CurrentAttributes (ExecutionContext), LogSubscriber.

module RactorRailsShim
  class << self
    # Patch ActiveSupport::Inflector::Inflections to not read @__en_instance__
    # / @__instance__ class ivars from a worker Ractor. The inflections instance
    # holds rules (Arrays/Hashes of Strings) populated at boot; for a frozen
    # shared app it's read-only. Workers share the main-ractor's inflections
    # instance via a shareable fallback (made shareable in place). `instance`
    # / `instance_or_fallback` are called per-request during routing (camelize).
    def _install_inflector_patch
      return if @inflector_patched
      @inflector_patched = true
      _register_patch :inflector, "8.1"
      return unless defined?(::ActiveSupport::Inflector::Inflections)
      inf = ::ActiveSupport::Inflector::Inflections
      en_key = :ractor_rails_shim_inflections_en
      inst_key = :ractor_rails_shim_inflections_instance
      en_key_str = en_key.inspect
      inst_key_str = inst_key.inspect
      inf.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def instance(locale = :en)
          if locale == :en
            v = ActiveSupport::IsolatedExecutionState[#{en_key_str}]
            return v unless v.nil?
            if Ractor.main?
              existing = instance_variable_get(:@__en_instance__) if instance_variable_defined?(:@__en_instance__)
              ActiveSupport::IsolatedExecutionState[#{en_key_str}] = existing
              return existing || new.tap { |i| instance_variable_set(:@__en_instance__, i) }
            end
            fb = RactorRailsShim::SHAREABLE_FALLBACK[#{en_key_str}]
            return fb if fb
            built = new
            ActiveSupport::IsolatedExecutionState[#{en_key_str}] = built
            built
          else
            h = ActiveSupport::IsolatedExecutionState[#{inst_key_str}] ||= (Ractor.main? ? (instance_variable_defined?(:@__instance__) ? instance_variable_get(:@__instance__) : Concurrent::Map.new) : Concurrent::Map.new)
            h[locale] ||= new
          end
        end

        def instance_or_fallback(locale)
          return instance(locale) if locale == :en
          h = ActiveSupport::IsolatedExecutionState[#{inst_key_str}]
          if h && h.key?(locale)
            return h[locale]
          end
          if Ractor.main? && instance_variable_defined?(:@__instance__)
            iv = instance_variable_get(:@__instance__)
            return iv[locale] if iv && iv.key?(locale)
          end
          instance(locale)
        end
      RUBY
      # Register so _build_shareable_fallback! captures the :en inflections
      # instance (made shareable) for workers.
      CLASS_ATTRIBUTES << ["ActiveSupport::Inflector::Inflections", :__en_instance__, en_key, nil]
      # Materialize the :en instance into IES in main so the fallback builder
      # can read + share it.
      inf.instance(:en) if Ractor.main?
    end

    # Patch ActiveSupport module's @error_reporter class ivar (defined via
    # `singleton_class.attr_accessor :error_reporter` in active_support.rb:109)
    # to not read from a worker Ractor. ExecutionWrapper.error_reporter delegates
    # to ActiveSupport.error_reporter, which reads the @error_reporter ivar on
    # the ActiveSupport module. Workers get a fresh ErrorReporter (no subscribers
    # — correct for a read-only shared app where error reporting already ran
    # in main via the Rails.error mechanism). Called per-request via
    # ActionDispatch::Executor middleware.
    def _install_active_support_error_reporter_patch
      return if @error_reporter_patched
      @error_reporter_patched = true
      _register_patch :error_reporter, "8.1"
      return unless defined?(::ActiveSupport)
      er_key = :ractor_rails_shim_active_support_error_reporter
      er_key_str = er_key.inspect
      ::ActiveSupport.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def error_reporter
          v = ActiveSupport::IsolatedExecutionState[#{er_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@error_reporter)
            @error_reporter
          else
            built = ActiveSupport::ErrorReporter.new
            ActiveSupport::IsolatedExecutionState[#{er_key_str}] = built
            built
          end
        end
        def error_reporter=(val)
          ActiveSupport::IsolatedExecutionState[#{er_key_str}] = val
          @error_reporter = val if Ractor.main?
          val
        end
      RUBY
    end

    # Patch I18n::Config's class-variable-backed accessors (default_locale,
    # locale, backend, etc.) to not read @@cvars from a worker Ractor. I18n
    # defines these manually (`@@default_locale ||= :en`), not via
    # cattr_accessor, so the shim's mattr rewrite doesn't catch them. The
    # values are frozen Symbols / shareable config objects; route the
    # frequently-read ones (default_locale, locale) through IES with the same
    # default. Read per-request during view lookup (LookupContext details).
    def _install_i18n_patch
      return if @i18n_patched
      @i18n_patched = true
      _register_patch :i18n, "8.1"
      return unless defined?(::I18n::Config)
      cfg = ::I18n::Config
      dl_key = :ractor_rails_shim_i18n_default_locale
      l_key = :ractor_rails_shim_i18n_locale
      dl_key_str = dl_key.inspect
      l_key_str = l_key.inspect
      cfg.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_locale
          v = ActiveSupport::IsolatedExecutionState[#{dl_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@default_locale)
            cv = class_variable_get(:@@default_locale)
            ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = cv
            return cv
          end
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = :en
          :en
        end
        def default_locale=(locale)
          v = locale && locale.to_sym
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = v
          class_variable_set(:@@default_locale, v) if Ractor.main?
          v
        end
        def locale
          v = ActiveSupport::IsolatedExecutionState[#{l_key_str}]
          return v unless v.nil?
          default_locale
        end
        def locale=(locale)
          v = locale && locale.to_sym
          ActiveSupport::IsolatedExecutionState[#{l_key_str}] = v
          v
        end
      RUBY

      # Patch I18n.fallbacks (a singleton method on the I18n module) to not
      # read the @@fallbacks class variable from a worker Ractor. It already
      # uses Fiber/Thread-local storage with @@fallbacks as the fallback;
      # route the @@fallbacks read through IES so workers build their own
      # I18n::Locale::Fallbacks. Called per-request via LookupContext details.
      if defined?(::I18n)
        i18n = ::I18n
        fb_key = :ractor_rails_shim_i18n_fallbacks
        fb_key_str = fb_key.inspect
        i18n.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def fallbacks
            v = ActiveSupport::IsolatedExecutionState[#{fb_key_str}]
            return v unless v.nil?
            if Ractor.main? && class_variable_defined?(:@@fallbacks)
              cv = class_variable_get(:@@fallbacks)
              if cv
                ActiveSupport::IsolatedExecutionState[#{fb_key_str}] = cv
                return cv
              end
            end
            built = I18n::Locale::Fallbacks.new
            ActiveSupport::IsolatedExecutionState[#{fb_key_str}] = built
            built
          end
        RUBY

        # I18n::Locale::Tag.implementation — manual @@implementation ||= Simple.
        # The value is a module (shareable). Route through IES.
        if defined?(::I18n::Locale::Tag)
          tag = ::I18n::Locale::Tag
          tag_key = :ractor_rails_shim_i18n_tag_implementation
          tag_key_str = tag_key.inspect
          tag.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def implementation
              v = ActiveSupport::IsolatedExecutionState[#{tag_key_str}]
              return v unless v.nil?
              if Ractor.main? && class_variable_defined?(:@@implementation)
                cv = class_variable_get(:@@implementation)
                ActiveSupport::IsolatedExecutionState[#{tag_key_str}] = cv
                return cv
              end
              ActiveSupport::IsolatedExecutionState[#{tag_key_str}] = I18n::Locale::Tag::Simple
              I18n::Locale::Tag::Simple
            end
          RUBY
        end
      end
    end

    # Patch ActiveSupport::ExecutionContext — the @after_change_callbacks
    # class ivar and nestable are read/written per-request. Route through
    # IES; workers get empty arrays (correct for a read-only shared app
    # where ExecutionContext is per-Ractor and starts empty in a fresh
    # worker).
    def _install_execution_context_patch
      return if @exec_context_patched
      @exec_context_patched = true
      _register_patch :execution_context, "8.1"
      return unless defined?(::ActiveSupport::ExecutionContext)
      ec = ::ActiveSupport::ExecutionContext
      acb_key = :ractor_rails_shim_exec_context_after_change_callbacks
      nest_key = :ractor_rails_shim_exec_context_nestable
      acb_key_str = acb_key.inspect
      nest_key_str = nest_key.inspect
      ec.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def after_change_callbacks
          v = ActiveSupport::IsolatedExecutionState[#{acb_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@after_change_callbacks)
            v = @after_change_callbacks
            ActiveSupport::IsolatedExecutionState[#{acb_key_str}] = v
            v
          else
            arr = []
            ActiveSupport::IsolatedExecutionState[#{acb_key_str}] = arr
            arr
          end
        end
        def after_change(&block)
          after_change_callbacks << block
        end
        def nestable
          v = ActiveSupport::IsolatedExecutionState[#{nest_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@nestable)
            v = @nestable
            ActiveSupport::IsolatedExecutionState[#{nest_key_str}] = v
            v
          else
            false
          end
        end
        def nestable=(val)
          ActiveSupport::IsolatedExecutionState[#{nest_key_str}] = val
          @nestable = val if Ractor.main?
          val
        end
      RUBY
      # Rewrite the methods that read @after_change_callbacks directly.
      ec.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def set(**options)
          options.symbolize_keys!
          keys = options.keys
          store = record.store
          previous_context = if block_given?
            keys.zip(store.values_at(*keys)).to_h
          end
          store.merge!(options)
          after_change_callbacks.each(&:call)
          if block_given?
            begin
              yield
            ensure
              store.merge!(previous_context)
              after_change_callbacks.each(&:call)
            end
          end
        end
        def []=(key, value)
          record.store[key.to_sym] = value
          after_change_callbacks.each(&:call)
        end
      RUBY
    end

    # Patch ActiveSupport::LogSubscriber.logger — a raw class ivar with lazy
    # init (@logger ||= Rails.logger) that's WRITTEN at request teardown via
    # flush_all!. Workers can't write class ivars → IsolationError. Route
    # through IES; workers get Rails.logger (which the shim already routes
    # through IES) so it resolves to the worker's own per-Ractor logger.
    def _install_log_subscriber_patch
      return if @log_subscriber_patched
      @log_subscriber_patched = true
      _register_patch :log_subscriber, "8.1"
      return unless defined?(::ActiveSupport::LogSubscriber)
      ls = ::ActiveSupport::LogSubscriber
      key = :ractor_rails_shim_log_subscriber_logger
      key_str = key.inspect
      ls.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def logger
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@logger)
            @logger
          elsif defined?(::Rails) && ::Rails.respond_to?(:logger)
            ::Rails.logger
          end
        end

        def logger=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
        end
      RUBY
    end
  end
end
