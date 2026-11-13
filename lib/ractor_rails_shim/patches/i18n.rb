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
        # --- Config accessors rewritten to be Ractor-safe -------------------
        # In the MAIN Ractor the upstream i18n implementation runs VERBATIM
        # (class variables and the per-fiber config instance are both
        # main-local, so Ractor::IsolationError cannot occur). In worker
        # Ractors the class-variable reads/writes are replaced by
        # per-Ractor IsolatedExecutionState storage with the documented
        # defaults. Main fidelity = upstream fidelity: readers use ||= /
        # delegation semantics exactly like i18n's own config.rb, so no
        # explicit-nil or stale-cache divergence is possible.
        def locale
          if Ractor.main?
            defined?(@locale) && !@locale.nil? ? @locale : default_locale
          else
            v = RactorRailsShim.storage[#{l_key_str}]
            v.nil? ? default_locale : v
          end
        end
        def locale=(locale)
          # Upstream setters enforce available locales. Skip in workers:
          # worker-local backends may not know every locale yet and raising
          # here would break worker boot paths.
          I18n.enforce_available_locales!(locale) if Ractor.main?
          v = locale && locale.to_sym
          if Ractor.main?
            @locale = v
          else
            RactorRailsShim.storage[#{l_key_str}] = v
          end
          v
        end
        def default_locale
          if Ractor.main?
            @@default_locale ||= :en
          else
            v = RactorRailsShim.storage[#{dl_key_str}]
            v.nil? ? :en : v
          end
        end
        def default_locale=(locale)
          I18n.enforce_available_locales!(locale) if Ractor.main?
          v = locale && locale.to_sym
          if Ractor.main?
            @@default_locale = v
          else
            RactorRailsShim.storage[#{dl_key_str}] = v
          end
          v
        end
        # available_locales is read per-request during view template lookup
        # (ActionView::Resolver::PathParser#build_path_regex). Upstream
        # delegates to the backend whenever not explicitly set (never
        # caches the delegated value). Workers cannot read the class var,
        # so they default to [:en] WITHOUT delegating (that path reads the
        # @@backend / @@load_path class vars, which are unreadable from a
        # worker). The template-regex path only needs the locale list.
        def available_locales
          if Ractor.main?
            @@available_locales ||= nil
            @@available_locales || backend.available_locales
          else
            v = RactorRailsShim.storage[#{av_key_str}]
            v.nil? ? [:en].freeze : v
          end
        end
        def available_locales=(locales)
          if Ractor.main?
            @@available_locales = Array(locales).map { |locale| locale.to_sym }
            @@available_locales = nil if @@available_locales.empty?
            @@available_locales_set = nil
            @@available_locales
          else
            v = Array(locales).map { |l| l.to_sym }
            v = nil if v.empty?
            RactorRailsShim.storage[#{av_key_str}] = v
            RactorRailsShim.storage[#{avs_key_str}] = nil
            v
          end
        end
        # Caches the available locales list as strings and symbols in a Set
        # for fast availability checks (upstream verbatim in main).
        def available_locales_set
          if Ractor.main?
            @@available_locales_set ||= available_locales.inject(Set.new) do |set, locale|
              set << locale.to_s << locale.to_sym
            end
          else
            v = RactorRailsShim.storage[#{avs_key_str}]
            unless v
              v = available_locales.inject(Set.new) do |set, locale|
                set << locale.to_s << locale.to_sym
              end
              RactorRailsShim.storage[#{avs_key_str}] = v
            end
            v
          end
        end
        # Clears the set so it can be recomputed after I18n reloads
        # (upstream verbatim in main).
        def clear_available_locales_set
          if Ractor.main?
            @@available_locales_set = nil
          else
            RactorRailsShim.storage[#{avs_key_str}] = nil
          end
          nil
        end
        # Returns true if the available_locales have been initialized
        # (upstream verbatim in main).
        def available_locales_initialized?
          if Ractor.main?
            !!defined?(@@available_locales) && !!@@available_locales
          else
            !!(RactorRailsShim.storage[#{av_key_str}])
          end
        end
        # enforce_available_locales is read during every I18n.translate. The
        # @@ class var exists from the moment the gem loads (upstream
        # initializes it to true at class level), so the main read is safe.
        def enforce_available_locales
          if Ractor.main?
            @@enforce_available_locales
          else
            v = RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce]
            v.nil? ? true : v
          end
        end
        def enforce_available_locales=(val)
          if Ractor.main?
            @@enforce_available_locales = val
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_enforce] = val
          end
          val
        end
        # backend reads the @@backend class variable (which a worker Ractor
        # cannot access). The backend holds the loaded translations. Because
        # the translation data can contain Procs (e.g. `number.nth.ordinals`
        # in ActiveSupport's en locale), the whole backend cannot be
        # deep-frozen and shared. Instead, each worker builds its OWN backend
        # instance (of the same class as the main backend, so fallbacks etc.
        # are preserved) and lazy-loads translations from the shareable
        # +load_path+ (see the patched `load_path`/`load_path=`). The
        # worker-local backend is mutable (its @interpolations Proc is
        # created in the worker, so it's fine).
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
          if Ractor.main?
            @@backend = value
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_backend] = value
          end
          value
        end
        # load_path reads the @@load_path class variable (unreadable from a
        # worker). Capture the (shareable) list of translation file paths in
        # main; workers reload translations from disk via these paths.
        def load_path
          if Ractor.main?
            @@load_path ||= []
          else
            v = RactorRailsShim.storage[:ractor_rails_shim_i18n_load_path]
            v.nil? ? (RactorRailsShim.const_defined?(:I18N_LOAD_PATH) ? RactorRailsShim::I18N_LOAD_PATH : []) : v
          end
        end
        # Upstream load_path= also clears the available_locales set (the
        # backend's locale list may change after reload) and reloads the
        # backend. Workers only rearm their shareable path list.
        def load_path=(load_path)
          if Ractor.main?
            @@load_path = load_path
            @@available_locales_set = nil
            backend.reload!
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_load_path] = Array(load_path)
          end
          load_path
        end
        # default_separator / exception_handler / interpolation_patterns /
        # missing_interpolation_argument_handler each read a @@ class
        # variable unreadable from a worker. Main runs upstream verbatim;
        # workers use the documented default (each default is worker-local
        # and shareable-safe: a String, a fresh ExceptionHandler, a fresh
        # lambda, or the frozen DEFAULT_INTERPOLATION_PATTERNS constant).
        def default_separator
          Ractor.main? ? (@@default_separator ||= ".") : (RactorRailsShim.storage[:ractor_rails_shim_i18n_sep] || ".")
        end
        def default_separator=(separator)
          if Ractor.main?
            @@default_separator = separator
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_sep] = separator
          end
          separator
        end
        def exception_handler
          if Ractor.main?
            @@exception_handler ||= ::I18n::ExceptionHandler.new
          else
            v = RactorRailsShim.storage[:ractor_rails_shim_i18n_exc]
            v.nil? ? ::I18n::ExceptionHandler.new : v
          end
        end
        def exception_handler=(handler)
          if Ractor.main?
            @@exception_handler = handler
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_exc] = handler
          end
          handler
        end
        def missing_interpolation_argument_handler
          if Ractor.main?
            @@missing_interpolation_argument_handler ||= lambda do |missing_key, provided_hash, string|
              raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
            end
          else
            v = RactorRailsShim.storage[:ractor_rails_shim_i18n_miss]
            if v.nil?
              lambda do |missing_key, provided_hash, string|
                raise ::I18n::MissingInterpolationArgument.new(missing_key, provided_hash, string)
              end
            else
              v
            end
          end
        end
        def missing_interpolation_argument_handler=(handler)
          if Ractor.main?
            @@missing_interpolation_argument_handler = handler
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_miss] = handler
          end
          handler
        end
        def interpolation_patterns
          if Ractor.main?
            @@interpolation_patterns ||= ::I18n::DEFAULT_INTERPOLATION_PATTERNS.dup
          else
            v = RactorRailsShim.storage[:ractor_rails_shim_i18n_ip]
            v.nil? ? ::I18n::DEFAULT_INTERPOLATION_PATTERNS : v
          end
        end
        def interpolation_patterns=(patterns)
          if Ractor.main?
            @@interpolation_patterns = patterns
          else
            RactorRailsShim.storage[:ractor_rails_shim_i18n_ip] = patterns
          end
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

      # Patch I18n.fallbacks (a singleton method on the I18n module). Upstream
      # reads `@@fallbacks ||= I18n::Locale::Fallbacks.new` then
      # `Fiber[:i18n_fallbacks] || @@fallbacks`. In main run upstream
      # VERBATIM — the setter (upstream, unpatched) writes @@fallbacks and
      # the fiber local, so caching in IES would go stale. Workers cannot
      # read the class var, so they use per-worker IES storage and build
      # their own I18n::Locale::Fallbacks lazily. Called per-request via
      # LookupContext details.
      if defined?(::I18n)
        i18n = ::I18n
        fb_key = :ractor_rails_shim_i18n_fallbacks
        fb_key_str = fb_key.inspect
        i18n.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def fallbacks
            if Ractor.main?
              @@fallbacks ||= ::I18n::Locale::Fallbacks.new
              Fiber[:i18n_fallbacks] || @@fallbacks
            else
              v = RactorRailsShim.storage[#{fb_key_str}]
              return v unless v.nil?
              built = ::I18n::Locale::Fallbacks.new
              RactorRailsShim.storage[#{fb_key_str}] = built
              built
            end
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
              return v unless v.nil?
              return nil if RactorRailsShim.storage.key?(#{tag_key_str})
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
          # The integer-key regex is built OUTSIDE the heredoc: in an
          # interpolated heredoc, Ruby strips unrecognized escapes (\A, \d,
          # \z) from the body text, which silently turns the compiled regex
          # into /A[-+]?([1-9]d*|0)z/ (never matches — integer key segments
          # came out as Symbols). Interpolating a pre-built literal keeps
          # the escapes intact in the generated code.
          nk_int_re = /\A[-+]?([1-9]\d*|0)\z/
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
                    when #{nk_int_re.inspect} # integer
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
    # #store_translations. The original's `translations` default block takes
    # the MUTEX constant (`MUTEX` is a non-shareable Mutex on the module), so
    # a worker Ractor that builds its own (per the patched I18n::Config#backend)
    # backend and lazy-loads translations hits "can not access non-shareable
    # objects in constant ...MUTEX". Worker-local backends are single-threaded
    # (a Ractor serializes its requests), so the lazy subhash creation drops
    # the mutex — but keeps upstream's Concurrent::Hash default-block
    # semantics exactly: reading translations[locale] for an unstored locale
    # must return an empty Concurrent::Hash (tests assert translations[:xx]
    # == {} after a rejected store), not nil. Applied at prepare_for_ractors!
    # time (after the i18n backend class is loaded).
    def _install_i18n_backend_patch
      return if @i18n_backend_patched
      @i18n_backend_patched = true
      _register_patch :i18n_backend, "8.1"
      return unless defined?(::I18n::Backend::Simple::Implementation)
      impl = ::I18n::Backend::Simple::Implementation
      impl.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def translations(do_init: false)
          init_translations if do_init && !initialized?
          @translations ||= Concurrent::Hash.new do |h, k|
            h[k] = Concurrent::Hash.new
          end
        end
        def store_translations(locale, data, options = ::I18n::EMPTY_HASH)
          if ::I18n.enforce_available_locales &&
             ::I18n.available_locales_initialized? &&
             !::I18n.locale_available?(locale)
            return data
          end
          locale = locale.to_sym
          translations[locale] ||= Concurrent::Hash.new
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
              $3 ? sprintf("%\#{$3}", value) : value
            end
          end

          interpolated ? interpolated_string : string
        end
      RUBY
    end
  end
end
