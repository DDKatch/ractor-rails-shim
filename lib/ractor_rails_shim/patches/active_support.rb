# frozen_string_literal: true

# Patches for ActiveSupport: Inflector::Inflections, ErrorReporter,
# CurrentAttributes (ExecutionContext), LogSubscriber, Callbacks,
# Notifications, Reloader, LocalCache, CachingKeyGenerator,
# Messages::SerializerWithFallback, JSON::Encoding.
# I18n patches are in patches/i18n.rb.

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
    # Patch ActiveSupport::Callbacks#run_callbacks to tolerate a nil
    # __callbacks (the case in worker Ractors whose class_attribute fallback
    # couldn't be made shareable because callback chains hold frozen,
    # self-capturing Procs). For a frozen, read-only shared app the boot-time
    # callbacks (ExecutionContext push/pop, CurrentAttributes clear) already
    # ran in the main Ractor at boot; worker Ractors don't need to re-run
    # them per request (CurrentAttributes/ExecutionContext are thread-local,
    # hence per-Ractor, and start empty in a fresh worker). When __callbacks
    # is nil, run_callbacks just yields the block — matching the empty-chain
    # fast path in the original. Moved here from execution_wrapper.rb (it
    # patches ActiveSupport::Callbacks, not ExecutionWrapper).
    def _install_callbacks_nil_safe_patch
      return if @callbacks_nil_safe_patched
      @callbacks_nil_safe_patched = true
      _register_patch :callbacks_nil_safe, "8.1"
      return unless defined?(::ActiveSupport::Callbacks)
      ::ActiveSupport::Callbacks.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def run_callbacks_with_nil_safe(kind, type = nil)
          kind = kind.to_sym
          strategy = RactorRailsShim.storage_strategy
          if kind == :process_action && defined?(::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS)
            # Thread (Puma/Falcon) mode: replay_callbacks! always replays
            # (replay_callbacks? returns false → block runs).
            # Ractor mode: replays only when __callbacks is empty
            # (replay_callbacks? returns true → skipped when callbacks present).
            callbacks = __callbacks[kind] if __callbacks
            return strategy.replay_callbacks!(self, kind) { (yield if block_given?) } if strategy.replay_callbacks?(callbacks)
          end
          callbacks = __callbacks[kind] if __callbacks
          if callbacks.nil? || callbacks.empty?
            yield if block_given?
          else
            run_callbacks_without_nil_safe(kind, type) { yield if block_given? }
          end
        end
        alias_method :run_callbacks_without_nil_safe, :run_callbacks
        alias_method :run_callbacks, :run_callbacks_with_nil_safe
      RUBY
    end

    # Patch ActiveSupport::Notifications.notifier to not read the @notifier
    # class ivar from a worker Ractor. The original is `attr_accessor
    # :notifier` with `@notifier = Fanout.new` set at module load — a raw
    # class ivar holding a Fanout (which has a Mutex + subscriber Procs,
    # both unshareable). Workers get their own per-Ractor Fanout (no
    # subscribers — instrumentation is a no-op in workers, which is correct
    # for a read-only shared app where log subscribers already ran in main).
    # `notifier` is read by `instrumenter` (per-request via Rails::Rack::Logger).
    # Moved here from execution_wrapper.rb (it patches ActiveSupport::
    # Notifications, not ExecutionWrapper).
    def _install_notifications_notifier_patch
      return if @notifications_notifier_patched
      @notifications_notifier_patched = true
      _register_patch :notifications_notifier, "8.1"
      return unless defined?(::ActiveSupport::Notifications)
      notif = ::ActiveSupport::Notifications
      nkey = :ractor_rails_shim_notifications_notifier
      nkey_str = nkey.inspect
      notif.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def notifier
          v = RactorRailsShim.storage[#{nkey_str}]
          return v if RactorRailsShim.storage.key?(#{nkey_str})
          if Ractor.main? && instance_variable_defined?(:@notifier)
            @notifier
          else
            built = ActiveSupport::Notifications::Fanout.new
            RactorRailsShim.storage[#{nkey_str}] = built
            built
          end
        end
      RUBY
    end

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
            v = RactorRailsShim.storage[#{en_key_str}]
            return v if RactorRailsShim.storage.key?(#{en_key_str})
            if Ractor.main?
              existing = instance_variable_get(:@__en_instance__) if instance_variable_defined?(:@__en_instance__)
              RactorRailsShim.storage[#{en_key_str}] = existing
              return existing || new.tap { |i| instance_variable_set(:@__en_instance__, i) }
            end
            fb = RactorRailsShim::SHAREABLE_FALLBACK[#{en_key_str}]
            return fb if fb
            built = new
            RactorRailsShim.storage[#{en_key_str}] = built
            built
          else
            h = RactorRailsShim.storage[#{inst_key_str}] ||= (Ractor.main? ? (instance_variable_defined?(:@__instance__) ? instance_variable_get(:@__instance__) : Concurrent::Map.new) : Concurrent::Map.new)
            h[locale] ||= new
          end
        end

        def instance_or_fallback(locale)
          return instance(locale) if locale == :en
          h = RactorRailsShim.storage[#{inst_key_str}]
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
              store = (RactorRailsShim.storage[:rrs_module_parent_names] ||= {})
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
          v = RactorRailsShim.storage[#{er_key_str}]
          return v if RactorRailsShim.storage.key?(#{er_key_str})
          if Ractor.main? && instance_variable_defined?(:@error_reporter)
            @error_reporter
          else
            built = ActiveSupport::ErrorReporter.new
            RactorRailsShim.storage[#{er_key_str}] = built
            built
          end
        end
        def error_reporter=(val)
          RactorRailsShim.storage[#{er_key_str}] = val
          @error_reporter = val if Ractor.main?
          val
        end
      RUBY
    end

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
          v = RactorRailsShim.storage[#{acb_key_str}]
          return v if RactorRailsShim.storage.key?(#{acb_key_str})
          if Ractor.main? && instance_variable_defined?(:@after_change_callbacks)
            v = @after_change_callbacks
            RactorRailsShim.storage[#{acb_key_str}] = v
            v
          else
            arr = []
            RactorRailsShim.storage[#{acb_key_str}] = arr
            arr
          end
        end
        def after_change(&block)
          after_change_callbacks << block
        end
        def nestable
          v = RactorRailsShim.storage[#{nest_key_str}]
          return v if RactorRailsShim.storage.key?(#{nest_key_str})
          if Ractor.main? && instance_variable_defined?(:@nestable)
            v = @nestable
            RactorRailsShim.storage[#{nest_key_str}] = v
            v
          else
            false
          end
        end
        def nestable=(val)
          RactorRailsShim.storage[#{nest_key_str}] = val
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
          v = RactorRailsShim.storage[#{key_str}]
          return v if RactorRailsShim.storage.key?(#{key_str})
          if Ractor.main? && instance_variable_defined?(:@logger)
            @logger
          elsif defined?(::Rails) && ::Rails.respond_to?(:logger)
            ::Rails.logger
          end
        end

        def logger=(val)
          RactorRailsShim.storage[#{key_str}] = val
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
          v = RactorRailsShim.storage[#{key_str}]
          return v if RactorRailsShim.storage.key?(#{key_str})
          result = check.call
          RactorRailsShim.storage[#{key_str}] = result
          result
        end

        def reloaded!
          RactorRailsShim.storage[#{key_str}] = false
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
          store = (RactorRailsShim.storage[:ractor_rails_shim_caching_key_generator] ||= {})
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
            (RactorRailsShim.storage[:ractor_rails_shim_serializers] ||= {
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

      # MessagePackWithFallback#available? lazily memoizes `@available` directly
      # on the module. When a worker Ractor first deserializes a cookie,
      # SerializerWithFallback#load -> detect_format -> MessagePackWithFallback
      # .dumped? -> available? tries to SET that ivar, raising
      #   Ractor::IsolationError: can not set instance variables of
      #   classes/modules by non-main Ractors
      # Replace the ivar memoization with a pure constant check. The module is
      # shareable and ActiveSupport::MessagePack resolves to a shareable class,
      # so this is safe from any Ractor.
      ::ActiveSupport::Messages::SerializerWithFallback::MessagePackWithFallback.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def available?
          defined?(::ActiveSupport::MessagePack)
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
          encoder = RactorRailsShim.storage[#{ec_key_str}]
          encoder ||= (RactorRailsShim.storage[#{ec_key_str}] = RactorRailsShim::JSON_ENCODER_CLASS.new)
          encoder.encode(value)
        end
        def encode_without_escape(value)
          encoder = RactorRailsShim.storage[#{ecn_key_str}]
          encoder ||= (RactorRailsShim.storage[#{ecn_key_str}] = RactorRailsShim::JSON_ENCODER_CLASS.new(escape: false))
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
            rescue StandardError
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
