# frozen_string_literal: true

# I18n patches: I18n::Config accessors, I18n::Backend, I18n interpolation.
# Extracted from active_support.rb per POODR SRP — each concern owns its
# own file. The dispatcher discovers _install_i18n_patch etc. via the
# method table on RactorRailsShim's singleton class.

module RactorRailsShim
  class << self
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
          v = RactorRailsShim.storage[#{dl_key_str}]
          return v if RactorRailsShim.storage.key?(#{dl_key_str})
          if Ractor.main? && defined?(@@default_locale)
            cv = @@default_locale
            RactorRailsShim.storage[#{dl_key_str}] = cv
            return cv
          end
          RactorRailsShim.storage[#{dl_key_str}] = :en
          :en
        end
        def default_locale=(locale)
          v = locale && locale.to_sym
          RactorRailsShim.storage[#{dl_key_str}] = v
          @@default_locale = v if Ractor.main?
          v
        end
        def locale
          v = RactorRailsShim.storage[#{l_key_str}]
          return v if RactorRailsShim.storage.key?(#{l_key_str})
          default_locale
        end
        def locale=(locale)
          v = locale && locale.to_sym
          RactorRailsShim.storage[#{l_key_str}] = v
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
          v = RactorRailsShim.storage[#{av_key_str}]
          return v if RactorRailsShim.storage.key?(#{av_key_str})
          if Ractor.main?
            if defined?(@@available_locales) && (cv = @@available_locales)
              RactorRailsShim.storage[#{av_key_str}] = cv
              return cv
            end
            al = backend.available_locales
            al = al.freeze if al.respond_to?(:freeze) && !al.frozen?
            RactorRailsShim.storage[#{av_key_str}] = al
            return al
          end
          al = [:en].freeze
          RactorRailsShim.storage[#{av_key_str}] = al
          al
        end
        def available_locales=(locales)
          v = Array(locales).map { |l| l.to_sym }
          v = nil if v.empty?
          RactorRailsShim.storage[#{av_key_str}] = v
          @@available_locales = v if Ractor.main?
          v
        end
        def available_locales_set
          v = RactorRailsShim.storage[#{avs_key_str}]
          return v if RactorRailsShim.storage.key?(#{avs_key_str})
          if Ractor.main? && defined?(@@available_locales_set) && (cv = @@available_locales_set)
            RactorRailsShim.storage[#{avs_key_str}] = cv
            return cv
          end
          s = available_locales.inject(Set.new) { |set, locale| set << locale.to_s << locale.to_sym }
          RactorRailsShim.storage[#{avs_key_str}] = s
          s
        end
        def available_locales_initialized?
          !!(RactorRailsShim.storage[#{av_key_str}])
        end
        # enforce_available_locales is read during every I18n.translate (the
        # Label/tag translation path in views). The original reads the
        # @@enforce_available_locales class variable, which a worker Ractor
        # cannot access (Ractor::IsolationError). Route it through IES; in main
        # we mirror the class var, in a worker we default to `true` (the
        # documented I18n default).
        def enforce_available_locales
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_enforce)
          if Ractor.main? && defined?(@@enforce_available_locales)
            cv = @@enforce_available_locales
            RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce] = cv
            return cv
          end
          RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce] = true
          true
        end
        def enforce_available_locales=(val)
          v = !!val
          RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce] = v
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
            b = RactorRailsShim.storage[key]
            return b if b
            cls = (RactorRailsShim.const_defined?(:I18N_BACKEND_CLASS) && RactorRailsShim::I18N_BACKEND_CLASS) || ::I18n::Backend::Simple
            b = cls.new
            RactorRailsShim.storage[key] = b
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
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_load_path]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_load_path)
          if Ractor.main?
            lp = (defined?(@@load_path) && @@load_path) || []
            lp = lp.dup.freeze if lp.respond_to?(:freeze) && !lp.frozen?
            RactorRailsShim.storage[:ractor_rails_shim_i18n_load_path] = lp
            lp
          else
            RactorRailsShim.const_defined?(:I18N_LOAD_PATH) ? RactorRailsShim::I18N_LOAD_PATH : []
          end
        end
        def load_path=(lp)
          lp = Array(lp)
          RactorRailsShim.storage[:ractor_rails_shim_i18n_load_path] = lp
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
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_sep]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_sep)
          if Ractor.main?
            cv = defined?(@@default_separator) ? @@default_separator : "."
            RactorRailsShim.storage[:ractor_rails_shim_i18n_sep] = cv
            cv
          else
            "."
          end
        end
        def default_separator=(separator)
          RactorRailsShim.storage[:ractor_rails_shim_i18n_sep] = separator
          @@default_separator = separator if Ractor.main?
          separator
        end
        def exception_handler
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_exc]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_exc)
          if Ractor.main?
            cv = defined?(@@exception_handler) ? @@exception_handler : ::I18n::ExceptionHandler.new
            RactorRailsShim.storage[:ractor_rails_shim_i18n_exc] = cv
            cv
          else
            ::I18n::ExceptionHandler.new
          end
        end
        def exception_handler=(handler)
          RactorRailsShim.storage[:ractor_rails_shim_i18n_exc] = handler
          @@exception_handler = handler if Ractor.main?
          handler
        end
        def missing_interpolation_argument_handler
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_miss]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_miss)
          if Ractor.main?
            cv = defined?(@@missing_interpolation_argument_handler) ? @@missing_interpolation_argument_handler : lambda do |missing_key, provided_hash, string|
                raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
              end
            RactorRailsShim.storage[:ractor_rails_shim_i18n_miss] = cv
            cv
          else
            lambda do |missing_key, provided_hash, string|
                raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
              end
          end
        end
        def missing_interpolation_argument_handler=(handler)
          RactorRailsShim.storage[:ractor_rails_shim_i18n_miss] = handler
          @@missing_interpolation_argument_handler = handler if Ractor.main?
          handler
        end
        def interpolation_patterns
          v = RactorRailsShim.storage[:ractor_rails_shim_i18n_ip]
          return v if RactorRailsShim.storage.key?(:ractor_rails_shim_i18n_ip)
          if Ractor.main?
            cv = defined?(@@interpolation_patterns) ? @@interpolation_patterns : ::I18n::DEFAULT_INTERPOLATION_PATTERNS.dup
            RactorRailsShim.storage[:ractor_rails_shim_i18n_ip] = cv
            cv
          else
            ::I18n::DEFAULT_INTERPOLATION_PATTERNS
          end
        end
        def interpolation_patterns=(patterns)
          RactorRailsShim.storage[:ractor_rails_shim_i18n_ip] = patterns
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
        rescue StandardError
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
            v = RactorRailsShim.storage[#{fb_key_str}]
            return v if RactorRailsShim.storage.key?(#{fb_key_str})
            if Ractor.main? && defined?(@@fallbacks)
              cv = @@fallbacks
              if cv
                RactorRailsShim.storage[#{fb_key_str}] = cv
                return cv
              end
            end
            built = I18n::Locale::Fallbacks.new
            RactorRailsShim.storage[#{fb_key_str}] = built
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
              v = RactorRailsShim.storage[#{tag_key_str}]
              return v if RactorRailsShim.storage.key?(#{tag_key_str})
              if Ractor.main? && defined?(@@implementation)
                cv = @@implementation
                RactorRailsShim.storage[#{tag_key_str}] = cv
                return cv
              end
              RactorRailsShim.storage[#{tag_key_str}] = I18n::Locale::Tag::Simple
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
              cache = RactorRailsShim.storage[#{nk_key_str}]
              cache ||= (RactorRailsShim.storage[#{nk_key_str}] = ::I18n.new_double_nested_cache)
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
              v = RactorRailsShim.storage[#{rkp_key_str}]
              return v if v
              pat = /(?<!%)%\\{(#{::I18n::RESERVED_KEYS.join("|")})\\}/
              RactorRailsShim.storage[#{rkp_key_str}] = pat
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
          cache = (RactorRailsShim.storage[:ractor_rails_shim_i18n_interp_cache] ||= {})
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
  end
end
