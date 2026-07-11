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
    "ActiveSupport::ExecutionWrapper::Null",
    "Concurrent::NULL",
    "I18n::RESERVED_KEYS",
    # ActiveSupport::JSON::Encoding constants. The module is shareable, but its
    # constants hold values (Regexps built via Regexp.union, and a Hash of
    # frozen binary strings) that are NOT Ractor-shareable in Ruby 4.0, so a
    # worker Ractor cannot read them (HTML_ENTITIES_REGEX etc.). Deep-freeze
    # each into a shareable twin and const_set it back on the module.
    "ActiveSupport::JSON::Encoding::ESCAPED_CHARS",
    "ActiveSupport::JSON::Encoding::HTML_ENTITIES_REGEX",
    "ActiveSupport::JSON::Encoding::FULL_ESCAPE_REGEX",
    "ActiveSupport::JSON::Encoding::JS_SEPARATORS_REGEX",
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

    # Patch Module#module_parent_name so a worker Ractor does not write the
    # `@parent_name` class ivar on a shared (non-frozen) module. The default
    # memoizes `@parent_name ||= ...` on first use; when that first use happens
    # in a worker it writes a class ivar on a shared module, which raises
    # Ractor::IsolationError ("can not set instance variables of
    # classes/modules by non-main Ractors"). Route the per-worker cache through
    # IsolatedExecutionState (keyed by module object_id); main keeps the
    # original class-ivar behavior.
    def _install_module_introspection_patch
      return if @module_introspection_patched
      @module_introspection_patched = true
      _register_patch :module_introspection, "8.1"
      return unless defined?(::Module)
      ::Module.module_eval do
        def module_parent_name
          if defined?(@parent_name)
            @parent_name
          else
            name = self.name
            return if name.nil?

            parent_name = name =~ /::[^:]+\z/ ? -$` : nil
            if Ractor.main?
              @parent_name = parent_name unless frozen?
            else
              store = (ActiveSupport::IsolatedExecutionState[:rrs_module_parent_names] ||= {})
              store[object_id] ||= parent_name
            end
            parent_name
          end
        end
      end
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
          if Ractor.main? && defined?(@@default_locale)
            cv = @@default_locale
            ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = cv
            return cv
          end
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = :en
          :en
        end
        def default_locale=(locale)
          v = locale && locale.to_sym
          ActiveSupport::IsolatedExecutionState[#{dl_key_str}] = v
          @@default_locale = v if Ractor.main?
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
            if defined?(@@available_locales) && (cv = @@available_locales)
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
          @@available_locales = v if Ractor.main?
          v
        end
        def available_locales_set
          v = ActiveSupport::IsolatedExecutionState[#{avs_key_str}]
          return v unless v.nil?
          if Ractor.main? && defined?(@@available_locales_set) && (cv = @@available_locales_set)
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
          if Ractor.main? && defined?(@@enforce_available_locales)
            cv = @@enforce_available_locales
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = cv
            return cv
          end
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = true
          true
        end
        def enforce_available_locales=(val)
          v = !!val
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_enforce] = v
          @@enforce_available_locales = v if Ractor.main?
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
            lp = (defined?(@@load_path) && @@load_path) || []
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
          @@load_path = lp if Ractor.main?
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
            cv = defined?(@@default_separator) ? @@default_separator : "."
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_sep] = cv
            cv
          else
            "."
          end
        end
        def default_separator=(separator)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_sep] = separator
          @@default_separator = separator if Ractor.main?
          separator
        end
        def exception_handler
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc]
          return v unless v.nil?
          if Ractor.main?
            cv = defined?(@@exception_handler) ? @@exception_handler : ::I18n::ExceptionHandler.new
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc] = cv
            cv
          else
            ::I18n::ExceptionHandler.new
          end
        end
        def exception_handler=(handler)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_exc] = handler
          @@exception_handler = handler if Ractor.main?
          handler
        end
        def missing_interpolation_argument_handler
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_miss]
          return v unless v.nil?
          if Ractor.main?
            cv = defined?(@@missing_interpolation_argument_handler) ? @@missing_interpolation_argument_handler : lambda do |missing_key, provided_hash, string|
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
          @@missing_interpolation_argument_handler = handler if Ractor.main?
          handler
        end
        def interpolation_patterns
          v = ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip]
          return v unless v.nil?
          if Ractor.main?
            cv = defined?(@@interpolation_patterns) ? @@interpolation_patterns : ::I18n::DEFAULT_INTERPOLATION_PATTERNS.dup
            ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip] = cv
            cv
          else
            ::I18n::DEFAULT_INTERPOLATION_PATTERNS
          end
        end
        def interpolation_patterns=(patterns)
          ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_ip] = patterns
          @@interpolation_patterns = patterns if Ractor.main?
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
            if Ractor.main? && defined?(@@fallbacks)
              cv = @@fallbacks
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
              if Ractor.main? && defined?(@@implementation)
                cv = @@implementation
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

    # Patch I18n::Backend::Simple::Implementation#translations and
    # #store_translations. The original uses a MUTEX-backed Concurrent::Hash
    # default block (`MUTEX` is a non-shareable constant on the module), so a
    # worker Ractor that builds its own (per the patched I18n::Config#backend)
    # backend and lazy-loads translations hits "can not access non-shareable
    # objects in constant ...MUTEX". Worker-local backends are single-threaded
    # (a Ractor serializes its requests), so drop the mutex and use a plain
    # Hash. Applied at prepare_for_ractors! time (after the i18n backend class
    # is loaded).
    def _install_i18n_backend_patch
      return if @i18n_backend_patched
      @i18n_backend_patched = true
      _register_patch :i18n_backend, "8.1"
      return unless defined?(::I18n::Backend::Simple::Implementation)
      impl = ::I18n::Backend::Simple::Implementation
      impl.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def translations(do_init: false)
          init_translations if do_init && !initialized?
          @translations ||= {}
        end
        def store_translations(locale, data, options = {})
          if ::I18n.enforce_available_locales &&
             ::I18n.available_locales_initialized? &&
             !::I18n.locale_available?(locale)
            return data
          end
          locale = locale.to_sym
          translations[locale] ||= {}
          data = ::I18n::Utils.deep_symbolize_keys(data) unless options.fetch(:skip_symbolize_keys, false)
          ::I18n::Utils.deep_merge!(translations[locale], data)
        end
      RUBY
    end

    # Patch I18n.interpolate_hash. It reads INTERPOLATION_PATTERNS_CACHE — a
    # constant Hash with a default proc (unshareable) — to fetch the compiled
    # interpolation Regexp. A worker Ractor cannot read that constant, raising
    # "can not access non-shareable objects in constant
    # I18n::INTERPOLATION_PATTERNS_CACHE by non-main ractor". Route the cache
    # through IsolatedExecutionState so each Ractor compiles its own Regexp once.
    def _install_i18n_interpolation_patch
      return if @i18n_interpolation_patched
      @i18n_interpolation_patched = true
      _register_patch :i18n_interpolation, "8.1"
      return unless defined?(::I18n)
      ::I18n.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def interpolate_hash(string, values)
          patterns = config.interpolation_patterns
          cache = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_i18n_interp_cache] ||= {})
          pattern = cache[patterns] ||= ::Regexp.union(patterns)
          interpolated = false

          interpolated_string = string.gsub(pattern) do |match|
            interpolated = true

            if match == '%%'
              '%'
            else
              key = ($1 || $2 || match.tr("%{}", "")).to_sym
              value = if values.key?(key)
                        values[key]
                      else
                        config.missing_interpolation_argument_handler.call(key, values, string)
                      end
              value = value.call(values) if value.respond_to?(:call)
              $3 ? sprintf("%#{$3}", value) : value
            end
          end

          interpolated ? interpolated_string : string
        end
      RUBY
    end

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

    # Patch ActiveSupport::Reloader#check! / #reloaded!. These are CLASS
    # methods that memoize `@should_reload` in a class ivar. ActionDispatch::
    # Executor#call runs `Reloader.run!` -> `check!` on EVERY request, so a
    # worker Ractor writing that class ivar raises Ractor::IsolationError
    # ("can not set instance variables of classes/modules by non-main
    # Ractors"). Route the flag through IsolatedExecutionState so each Ractor
    # has its own. With reloading disabled (config.enable_reloading = false,
    # the right setting for a frozen, shared kino :ractor graph) check.call is
    # `lambda { false }`, so workers compute false (no reload) — but the write
    # must still be Ractor-safe.
    def _install_reloader_patch
      return if @reloader_patched
      @reloader_patched = true
      _register_patch :reloader, "8.1"
      return unless defined?(::ActiveSupport::Reloader)
      rl = ::ActiveSupport::Reloader
      key = :ractor_rails_shim_reloader_should_reload
      key_str = key.inspect
      rl.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def check!
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          result = check.call
          ActiveSupport::IsolatedExecutionState[#{key_str}] = result
          result
        end

        def reloaded!
          ActiveSupport::IsolatedExecutionState[#{key_str}] = false
        end
      RUBY
    end

    # Patch ActiveSupport::Cache::Strategy::LocalCache#local_cache_key. The
    # original memoizes the key in a `@local_cache_key` ivar on the store:
    #   `@local_cache_key ||= "...".to_sym`
    # When the store is part of the frozen, shared Rails.application graph
    # (deep-frozen by make_app_shareable! for kino :ractor mode), a worker
    # Ractor writing that ivar raises FrozenError. The key is a pure function
    # of the store's class + object_id (both stable for the shared object),
    # so compute it deterministically each call — no ivar write. The key still
    # addresses LocalCacheRegistry, which is already Ractor-safe (it uses
    # IsolatedExecutionState), so each Ractor keeps its own local cache.
    def _install_local_cache_patch
      return if @local_cache_patched
      @local_cache_patched = true
      _register_patch :local_cache, "8.1"
      return unless defined?(::ActiveSupport::Cache::Strategy::LocalCache)
      lc = ::ActiveSupport::Cache::Strategy::LocalCache
      lc.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def local_cache_key
          str = "\#{self.class.name.underscore}_local_cache_\#{object_id}".gsub(/[\\/-]/, "_")
          str.to_sym
        end
      RUBY
    end

    # Patch ActiveSupport::CachingKeyGenerator#generate_key. Its `@cache_keys`
    # ivar is a Concurrent::Map; make_app_shareable! rewrites Concurrent::Map
    # ivars into FROZEN Hashes (see make_shareable.rb), so a worker Ractor's
    # `@cache_keys[args.join("|")] ||= ...` write raises FrozenError. The cache
    # is pure memoization keyed by (generator, args), so route it through
    # IsolatedExecutionState (one mutable cache per Ractor). The inner
    # @key_generator.generate_key now works from workers thanks to the
    # OpenSSL::Digest lambda patch.
    def _install_caching_key_generator_patch
      return if @caching_key_generator_patched
      @caching_key_generator_patched = true
      _register_patch :caching_key_generator, "8.1"
      return unless defined?(::ActiveSupport::CachingKeyGenerator)
      ::ActiveSupport::CachingKeyGenerator.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def generate_key(*args)
          store = (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_caching_key_generator] ||= {})
          key = "\#{object_id}|\#{args.join("|")}"
          store.fetch(key) { store[key] = @key_generator.generate_key(*args) }
        end
      RUBY
    end

    # Patch ActiveSupport::Messages::SerializerWithFallback. Its SERIALIZERS
    # constant is a Hash of serializer modules — but the Hash itself is not
    # Ractor-shareable, so a worker Ractor reading it raises "can not access
    # non-shareable objects in constant ...SERIALIZERS". The individual
    # serializer modules ARE shareable, so route the lookup through
    # IsolatedExecutionState (a per-Ractor cache of the same module
    # references, which workers can read). `.load` resolves the fallback
    # serializer the same way.
    def _install_messages_serializer_patch
      return if @messages_serializer_patched
      @messages_serializer_patched = true
      _register_patch :messages_serializer, "8.1"
      return unless defined?(::ActiveSupport::Messages::SerializerWithFallback)
      swf = ::ActiveSupport::Messages::SerializerWithFallback
      swf.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def serializer_for(format)
          if Ractor.main?
            SERIALIZERS.fetch(format)
          else
            (ActiveSupport::IsolatedExecutionState[:ractor_rails_shim_serializers] ||= {
              marshal: ::ActiveSupport::Messages::SerializerWithFallback::MarshalWithFallback,
              json: ::ActiveSupport::Messages::SerializerWithFallback::JsonWithFallback,
              json_allow_marshal: ::ActiveSupport::Messages::SerializerWithFallback::JsonWithFallbackAllowMarshal,
              message_pack: ::ActiveSupport::Messages::SerializerWithFallback::MessagePackWithFallback,
              message_pack_allow_marshal: ::ActiveSupport::Messages::SerializerWithFallback::MessagePackWithFallbackAllowMarshal,
            })[format]
          end
        end

        def [](format)
          if format.to_s.include?("message_pack") && !defined?(::ActiveSupport::MessagePack)
            require "active_support/message_pack"
          end
          serializer_for(format)
        end
      RUBY
      swf.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def load(dumped)
          format = detect_format(dumped)
          if format == self.format
            _load(dumped)
          elsif format && fallback?(format)
            payload = { serializer: self.format, fallback: format, serialized: dumped }
            ActiveSupport::Notifications.instrument("message_serializer_fallback.active_support", payload) do
              payload[:deserialized] = serializer_for(format)._load(dumped)
            end
          else
            raise "Unsupported serialization format"
          end
        end
      RUBY
    end

    # Patch ActiveSupport::JSON::Encoding. The module memoizes two encoders in
    # class ivars (@encoder_without_options / @encoder_without_escape) inside
    # `json_encoder=`, and exposes `json_encoder` as a `attr_reader` (so it too
    # reads the @json_encoder class ivar). A worker Ractor cannot read any of
    # these module ivars, raising Ractor::IsolationError ("can not get
    # unshareable values from instance variables of classes/modules from
    # non-main Ractors"). Capture the encoder CLASS in main (on assignment) into
    # a shareable constant, then build a per-Ractor encoder instance via
    # IsolatedExecutionState instead of reading the module ivars.
    def _install_json_encoding_patch
      return if @json_encoding_patched
      @json_encoding_patched = true
      _register_patch :json_encoding, "8.1"
      return unless defined?(::ActiveSupport::JSON::Encoding)
      enc = ::ActiveSupport::JSON::Encoding
      ec_key = :ractor_rails_shim_json_encoder
      ec_key_str = ec_key.inspect
      ecn_key = :ractor_rails_shim_json_encoder_no_escape
      ecn_key_str = ecn_key.inspect
      enc.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def json_encoder=(encoder)
          RactorRailsShim.const_set(:JSON_ENCODER_CLASS, encoder) if Ractor.main? && defined?(RactorRailsShim)
          @json_encoder = encoder if Ractor.main?
          encoder
        end
        def json_encoder
          RactorRailsShim::JSON_ENCODER_CLASS
        end
        def encode_without_options(value)
          encoder = ActiveSupport::IsolatedExecutionState[#{ec_key_str}]
          encoder ||= (ActiveSupport::IsolatedExecutionState[#{ec_key_str}] = RactorRailsShim::JSON_ENCODER_CLASS.new)
          encoder.encode(value)
        end
        def encode_without_escape(value)
          encoder = ActiveSupport::IsolatedExecutionState[#{ecn_key_str}]
          encoder ||= (ActiveSupport::IsolatedExecutionState[#{ecn_key_str}] = RactorRailsShim::JSON_ENCODER_CLASS.new(escape: false))
          encoder.encode(value)
        end
      RUBY
      # The JSON encoding constants (HTML_ENTITIES_REGEX etc.) live on
      # ActiveSupport::JSON::Encoding but are NOT Ractor-shareable in Ruby 4.0
      # (Regexp.union / frozen-string Hash return false for Ractor.shareable?).
      # Deep-freeze + replace them here (in main, during prepare_for_ractors!)
      # so worker Ractors can read them when the encoder escapes HTML. Belt and
      # suspenders alongside the SHAREABLE_CONSTANTS registration.
      if Ractor.main?
        %w[ESCAPED_CHARS HTML_ENTITIES_REGEX FULL_ESCAPE_REGEX JS_SEPARATORS_REGEX].each do |name|
          next unless enc.const_defined?(name, false)
          v = enc.const_get(name, false)
          unless Ractor.shareable?(v)
            begin
              enc.const_set(name, Ractor.make_shareable(v))
            rescue
              nil
            end
          end
        end
      end
      # Make sure the constant exists on RactorRailsShim so worker references
      # resolve. It is set on the first `json_encoder=` call during init; seed a
      # default here so even a direct call before init is safe.
      unless RactorRailsShim.const_defined?(:JSON_ENCODER_CLASS)
        RactorRailsShim.const_set(:JSON_ENCODER_CLASS, ::ActiveSupport::JSON::Encoding::JSONGemEncoder)
      end
    end
  end
end
