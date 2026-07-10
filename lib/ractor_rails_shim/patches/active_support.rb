# frozen_string_literal: true

# Patches for ActiveSupport: Inflector::Inflections, ErrorReporter,
# I18n::Config, CurrentAttributes (ExecutionContext), LogSubscriber.

module RactorRailsShim
  # ActiveSupport + concurrent-ruby constants that need to be made shareable.
  SHAREABLE_CONSTANTS.concat([
    "ActiveSupport::EnvironmentInquirer::DEFAULT_ENVIRONMENTS",
    "ActiveSupport::EnvironmentInquirer::LOCAL_ENVIRONMENTS",
    "ActiveSupport::ErrorReporter::SEVERITIES",
    "ActiveSupport::CurrentAttributes::INVALID_ATTRIBUTE_NAMES",
    "ActiveSupport::Delegation::RUBY_RESERVED_KEYWORDS",
    "Concurrent::NULL",
    "I18n::RESERVED_KEYS",
  ])

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
      av_key = :ractor_rails_shim_i18n_available_locales
      avs_key = :ractor_rails_shim_i18n_available_locales_set
      dl_key_str = dl_key.inspect
      l_key_str = l_key.inspect
      av_key_str = av_key.inspect
      avs_key_str = avs_key.inspect
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
        # available_locales is read per-request during view template lookup
        # (ActionView::Resolver::PathParser#build_path_regex). The original
        # reads the @@available_locales class variable, which a worker Ractor
        # cannot access (Ractor::IsolationError). Route it through IES. In
        # main we mirror the class var; in a worker we default to [:en] WITHOUT
        # delegating to backend.available_locales (that path reads the @@backend
        # / @@load_path class vars, which are also unreadable from a worker).
        # The template-regex path only needs the list of locale symbols, and
        # [:en] is the documented I18n default — correct for apps that don't
        # set config.i18n.available_locales explicitly.
        def available_locales
          v = ActiveSupport::IsolatedExecutionState[#{av_key_str}]
          return v unless v.nil?
          if Ractor.main?
            if class_variable_defined?(:@@available_locales) && (cv = class_variable_get(:@@available_locales))
              ActiveSupport::IsolatedExecutionState[#{av_key_str}] = cv
              return cv
            end
            al = backend.available_locales
            al = al.freeze if al.respond_to?(:freeze) && !al.frozen?
            ActiveSupport::IsolatedExecutionState[#{av_key_str}] = al
            return al
          end
          al = [:en].freeze
          ActiveSupport::IsolatedExecutionState[#{av_key_str}] = al
          al
        end
        def available_locales=(locales)
          v = Array(locales).map { |l| l.to_sym }
          v = nil if v.empty?
          ActiveSupport::IsolatedExecutionState[#{av_key_str}] = v
          class_variable_set(:@@available_locales, v) if Ractor.main?
          v
        end
        def available_locales_set
          v = ActiveSupport::IsolatedExecutionState[#{avs_key_str}]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@available_locales_set) && (cv = class_variable_get(:@@available_locales_set))
            ActiveSupport::IsolatedExecutionState[#{avs_key_str}] = cv
            return cv
          end
          s = available_locales.inject(Set.new) { |set, locale| set << locale.to_s << locale.to_sym }
          ActiveSupport::IsolatedExecutionState[#{avs_key_str}] = s
          s
        end
        def available_locales_initialized?
          !!(ActiveSupport::IsolatedExecutionState[#{av_key_str}])
        end
        # enforce_available_locales is read during every I18n.translate (the
        # Label/tag translation path in views). The original reads the
        # @@enforce_available_locales class variable, which a worker Ractor
        # cannot access (Ractor::IsolationError). Route it through IES; in main
        # we mirror the class var, in a worker we default to `true` (the
        # documented I18n default).
        def enforce_available_locales
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce]
          return v unless v.nil?
          if Ractor.main? && class_variable_defined?(:@@enforce_available_locales)
            cv = class_variable_get(:@@enforce_available_locales)
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = cv
            return cv
          end
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = true
          true
        end
        def enforce_available_locales=(val)
          v = !!val
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = v
          class_variable_set(:@@enforce_available_locales, v) if Ractor.main?
          v
        end
        # backend reads the @@backend class variable (which a worker Ractor
        # cannot access). The backend holds the loaded translations. Because the
        # translation data can contain Procs (e.g. `number.nth.ordinals` in
        # ActiveSupport's en locale), the whole backend cannot be deep-frozen
        # and shared. Instead, each worker builds its OWN backend instance (of
        # the same class as the main backend, so fallbacks etc. are preserved)
        # and lazy-loads translations from the shareable +load_path+ (see the
        # patched `load_path`/`load_path=`). The worker-local backend is mutable
        # (its @interpolations Proc is created in the worker, so it's fine).
        def backend
          if Ractor.main?
            @@backend ||= ::I18n::Backend::Simple.new
          else
            key = :ractor_rails_shim_i18n_backend
            b = ActiveSupport::IsolatedExecutionState[key]
            return b if b
            cls = (RactorRailsShim.const_defined?(:I18N_BACKEND_CLASS) && RactorRailsShim::I18N_BACKEND_CLASS) || ::I18n::Backend::Simple
            b = cls.new
            ActiveSupport::IsolatedExecutionState[key] = b
            b
          end
        end
        def backend=(value)
          @@backend = value
        end
        # load_path reads the @@load_path class variable (unreadable from a
        # worker). Capture the (shareable) list of translation file paths in
        # main; workers reload translations from disk via these paths.
        def load_path
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_load_path]
          return v unless v.nil?
          if Ractor.main?
            lp = (class_variable_defined?(:@@load_path) && class_variable_get(:@@load_path)) || []
            lp = lp.dup.freeze if lp.respond_to?(:freeze) && !lp.frozen?
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_load_path] = lp
            lp
          else
            RactorRailsShim.const_defined?(:I18N_LOAD_PATH) ? RactorRailsShim::I18N_LOAD_PATH : []
          end
        end
        def load_path=(lp)
          lp = Array(lp)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_load_path] = lp
          class_variable_set(:@@load_path, lp) if Ractor.main?
          lp
        end
        # default_separator / exception_handler / missing_interpolation_argument_handler
        # / interpolation_patterns each read a @@ class variable unreadable from a
        # worker. Route them through IES; main mirrors the class var, workers use
        # the documented default (each default is worker-local and shareable-safe:
        # a String, a fresh ExceptionHandler, a fresh lambda, or the frozen
        # DEFAULT_INTERPOLATION_PATTERNS constant).
        def default_separator
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_sep]
          return v unless v.nil?
          if Ractor.main?
            cv = class_variable_defined?(:@@default_separator) ? class_variable_get(:@@default_separator) : "."
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_sep] = cv
            cv
          else
            "."
          end
        end
        def default_separator=(separator)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_sep] = separator
          class_variable_set(:@@default_separator, separator) if Ractor.main?
          separator
        end
        def exception_handler
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc]
          return v unless v.nil?
          if Ractor.main?
            cv = class_variable_defined?(:@@exception_handler) ? class_variable_get(:@@exception_handler) : ::I18n::ExceptionHandler.new
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc] = cv
            cv
          else
            ::I18n::ExceptionHandler.new
          end
        end
        def exception_handler=(handler)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc] = handler
          class_variable_set(:@@exception_handler, handler) if Ractor.main?
          handler
        end
        def missing_interpolation_argument_handler
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_miss]
          return v unless v.nil?
          if Ractor.main?
            cv = class_variable_defined?(:@@missing_interpolation_argument_handler) ? class_variable_get(:@@missing_interpolation_argument_handler) : lambda do |missing_key, provided_hash, string|
                raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
              end
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_miss] = cv
            cv
          else
            lambda do |missing_key, provided_hash, string|
                raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
              end
          end
        end
        def missing_interpolation_argument_handler=(handler)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_miss] = handler
          class_variable_set(:@@missing_interpolation_argument_handler, handler) if Ractor.main?
          handler
        end
        def interpolation_patterns
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip]
          return v unless v.nil?
          if Ractor.main?
            cv = class_variable_defined?(:@@interpolation_patterns) ? class_variable_get(:@@interpolation_patterns) : ::I18n::DEFAULT_INTERPOLATION_PATTERNS.dup
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip] = cv
            cv
          else
            ::I18n::DEFAULT_INTERPOLATION_PATTERNS
          end
        end
        def interpolation_patterns=(patterns)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip] = patterns
          class_variable_set(:@@interpolation_patterns, patterns) if Ractor.main?
          patterns
        end
      RUBY

      # Capture the I18n backend class and shareable load paths in MAIN after
      # the app has initialized. Workers build their own backend instance of
      # the captured class and reload translations from the captured load paths
      # (see `I18n::Config#backend` / `#load_path`). Eager-load the backend
      # class so the constant is globally defined for worker Ractors.
      if Ractor.main? && defined?(::I18n)
        begin
          # Eager-load I18n classes/constants in main so they are globally
          # defined for worker Ractors (which cannot autoload).
          ::I18n::Backend::Simple rescue nil
          ::I18n::ExceptionHandler rescue nil
          ::I18n::MissingInterpolationArgument rescue nil
          ::I18n::DEFAULT_INTERPOLATION_PATTERNS rescue nil
          backend = ::I18n.backend
          backend.translate(:en, "") rescue nil
          backend.available_locales rescue nil
          const_set(:I18N_BACKEND_CLASS, backend.class) unless RactorRailsShim.const_defined?(:I18N_BACKEND_CLASS)
          raw_lp = (backend.respond_to?(:instance_variable_get) && backend.instance_variable_get(:@load_path)) ||
                    (::I18n.respond_to?(:load_path) && ::I18n.load_path) || []
          shareable_lp = Ractor.make_shareable(Array(raw_lp).dup) rescue Array(raw_lp).map(&:to_s).freeze
          const_set(:I18N_LOAD_PATH, shareable_lp) unless RactorRailsShim.const_defined?(:I18N_LOAD_PATH)
        rescue
          nil
        end
      end

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

        # I18n::Base#normalize_key reads the @@normalized_key_cache class
        # variable (a double-nested Hash with default procs — unshareable, and
        # unreadable from a worker). It's a pure performance cache, so route it
        # through IsolatedExecutionState: each Ractor builds its own nested
        # cache via I18n.new_double_nested_cache and reads/writes it locally.
        if defined?(::I18n::Base)
          nk_key = :ractor_rails_shim_i18n_normalized_key_cache
          nk_key_str = nk_key.inspect
          ::I18n::Base.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def normalize_key(key, separator)
              cache = ActiveSupport::IsolatedExecutionState[#{nk_key_str}]
              cache ||= (ActiveSupport::IsolatedExecutionState[#{nk_key_str}] = ::I18n.new_double_nested_cache)
              cache[separator][key] ||=
                case key
                when Array
                  key.flat_map { |k| normalize_key(k, separator) }
                else
                  keys = key.to_s.split(separator)
                  keys.delete('')
                  keys.map! do |k|
                    case k
                    when /\A[-+]?([1-9]\d*|0)\z/ # integer
                      k.to_i
                    when 'true'
                      true
                    when 'false'
                      false
                    else
                      k.to_sym
                    end
                  end
                  keys
                end
            end
          RUBY
        end

        # I18n.reserved_keys_pattern memoizes its compiled regex in a lazy class
        # ivar (@reserved_keys_pattern) which a worker Ractor cannot write.
        # Route the cache through IsolatedExecutionState.
        if defined?(::I18n)
          rkp_key = :ractor_rails_shim_i18n_reserved_keys_pattern
          rkp_key_str = rkp_key.inspect
          ::I18n.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def reserved_keys_pattern
              v = ActiveSupport::IsolatedExecutionState[#{rkp_key_str}]
              return v if v
              pat = /(?<!%)%\\{(#{::I18n::RESERVED_KEYS.join("|")})\\}/
              ActiveSupport::IsolatedExecutionState[#{rkp_key_str}] = pat
              pat
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
