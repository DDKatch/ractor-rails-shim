# frozen_string_literal: true

# Patch Faraday (2.x) global state for worker Ractors. Faraday's state is raw
# class/module ivars + Monitor/Mutex constants — no mattr/class_attribute, so
# the shim's macro rewrites don't catch it. Runtime hot paths from a worker:
#
#   1. `Faraday::Utils::Headers#[]` / `#[]=` — read the KeyMap constant
#      (`Hash.new { |map, key| ... keymap_mutex.synchronize { ... } }`,
#      headers.rb:36-47): a Hash-with-default-Proc holding a captured Mutex.
#      EVERY header key lookup triggers the constant read → IsolationError
#      in workers, and the lazy fill synchronizes a main-Ractor Mutex.
#      Fix: main keeps the original KeyMap; workers map keys through a pure
#      per-Ractor cache (`::RactorRailsShim._faraday_header_key`) — same
#      capitalization function, no Mutex, no shared Hash.
#
#   2. `MiddlewareRegistry#registered_middleware` (+ Adapter's) — module ivar
#      Hash read + lazily PROMOTED (write) per connection build
#      (`rack_builder.rb:110-124`). Fix: capture the boot registrations into
#      a shareable snapshot; workers start from a Ractor-local mutable copy
#      of it (promotions stay local), the Monitor becomes a NoOpLock.
#
#   3. `Faraday::Middleware.default_options` — `@default_options ||=` on the
#      middleware subclass, written on first middleware instantiation inside
#      whichever Ractor builds the chain. Fix: workers build a frozen merged
#      copy per class via storage; main keeps the original memo.
#
#   4. `Faraday::Options.memoized_attributes` / `attribute_options` — class
#      ivar Hashes whose VALUES are constructor BLOCKS (un-shareable Procs as
#      written). `Options#[]` reads the table and `instance_eval(&block)`s it
#      on every memoized-attribute access. Fix: intercept the `memoized` /
#      `options` macros to attempt `::Ractor.make_shareable` on each block at
#      definition time (shareable Procs ARE callable from worker Ractors on
#      Ruby 3.2+, verified on 4.0.7) and capture each subclass's tables into
#      a shareable registry at install; workers read their class's frozen
#      tables. Un-shareable blocks keep the entry out of the worker table
#      (the option reads as nil — degraded, not crashing).
#
#   5. `Faraday::Options::Env.member_set` — `@member_set ||=` Set written on
#      first custom-key access in a worker. Fix: per-Ractor frozen Set.
#
#   6. `Faraday::Utils.default_params_encoder` / `default_uri_parser` /
#      `default_space_encoding` — module-ivar `||=` memoizations hit per
#      query escape/parse. Fix: per-Ractor storage memos (same values).
#
#   7. `Faraday::RackBuilder::NO_ARGUMENT` / `Handler::REGISTRY` /
#      `Faraday.default_adapter_options` — `NO_ARGUMENT` is an unfrozen bare
#      Object (fix: freeze); `default_adapter_options` is an unfrozen {}
#      (fix: freeze); `Handler` reads+WRITES the shared AdapterRegistry per
#      handler construction/lookup (fix: worker path uses plain
#      Object.const_get, no shared registry).
#
#   8. `Faraday.default_connection` — the module-level shortcut
#      (`Faraday.get/post`) memoizes ONE Connection on the module. Fix:
#      workers memoize their OWN connection via storage (correct: a
#      connection must not share its adapter/stack state across Ractors);
#      main keeps its own.

module RactorRailsShim
  class << self
    def _install_faraday_patch
      return if @faraday_patched
      @faraday_patched = true
      _register_patch :faraday, "8.1"
      return unless defined?(::Faraday)

      _freeze_faraday_trivial_constants
      _install_faraday_header_keymap
      _install_faraday_utils_memos
      _install_faraday_middleware_registry
      _install_faraday_default_options
      _install_faraday_options_tables
      _install_faraday_env_member_set
      _install_faraday_handler_registry
      _install_faraday_default_connection_options
      _install_faraday_default_connection
    end

    # Pure mapping function + per-Ractor cache for worker header lookups.
    # Public: called from eval'd worker code with an explicit receiver.
    def _faraday_header_key(key)
      return key if key.respond_to?(:to_str)
      cache = storage[:ractor_rails_shim_faraday_key_map]
      unless cache
        cache = {etag: "ETag"} # upstream pre-seed (KeyMap[:etag] = 'ETag')
        storage[:ractor_rails_shim_faraday_key_map] = cache
      end
      value = cache[key]
      unless value
        value = key.to_s.split("_").each(&:capitalize!).join("-")
        cache[key] = value
      end
      value
    end

    private

    def _freeze_faraday_trivial_constants
      return unless ::Ractor.main?
      # bare mutable Object default sentinel + unfrozen empty options hash
      no_arg = ::Faraday::RackBuilder.const_get(:NO_ARGUMENT) rescue nil
      if no_arg && !::Ractor.shareable?(no_arg)
        shared = ::Ractor.make_shareable(Object.new.freeze)
        verbose, $VERBOSE = $VERBOSE, nil
        begin
          ::Faraday::RackBuilder.send(:remove_const, :NO_ARGUMENT)
          ::Faraday::RackBuilder.const_set(:NO_ARGUMENT, shared)
        ensure
          $VERBOSE = verbose
        end
      end
      opts = ::Faraday.default_adapter_options
      ::Faraday.default_adapter_options = (opts || {}).freeze
      true
    rescue ::StandardError
      nil
    end

    def _install_faraday_header_keymap
      ::Faraday::Utils::Headers.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def [](key)
          key = ::Ractor.main? ? KeyMap[key] : ::RactorRailsShim._faraday_header_key(key)
          super || super(@names[key.downcase])
        end

        def []=(key, val)
          key = ::Ractor.main? ? KeyMap[key] : ::RactorRailsShim._faraday_header_key(key)
          key = (@names[key.downcase] ||= key)
          # join multiple values with a comma
          val = val.to_ary.join(', ') if val.respond_to?(:to_ary)
          super
        end
      RUBY
    end

    # NOTE: Faraday::Utils is a `module_function` module — the callable
    # (singleton) copies of these memoized readers live on
    # `Faraday::Utils.singleton_class`, so the redefinitions must land there.
    def _install_faraday_utils_memos
      ::Faraday::Utils.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_space_encoding
          if ::Ractor.main?
            @default_space_encoding ||= '+'
          else
            key = :ractor_rails_shim_faraday_space_encoding
            ::RactorRailsShim.storage[key] ||= '+'
            ::RactorRailsShim.storage[key]
          end
        end

        def default_params_encoder
          if ::Ractor.main?
            @default_params_encoder ||= NestedParamsEncoder
          else
            key = :ractor_rails_shim_faraday_params_encoder
            ::RactorRailsShim.storage[key] ||= ::Faraday::Utils::NestedParamsEncoder
            ::RactorRailsShim.storage[key]
          end
        end

        def default_uri_parser
          if ::Ractor.main?
            @default_uri_parser ||= ::Kernel.method(:URI)
          else
            key = :ractor_rails_shim_faraday_uri_parser
            ::RactorRailsShim.storage[key] ||= ::Kernel.method(:URI)
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_faraday_middleware_registry
      return unless defined?(::Faraday::MiddlewareRegistry)
      # Capture boot registrations from every module extending
      # MiddlewareRegistry — not just Middleware/Adapter: Faraday::Request
      # registers `:url_encoded` (part of the default rack-builder stack) and
      # Faraday::Response registers its status handlers. The default-stack
      # build (Faraday.new WITHOUT a block) looks them up off-main, so a
      # partial snapshot would raise "not registered on Faraday::Request".
      # Require faraday first so all extenders are present; a full
      # ObjectSpace walk keeps this correct even for non-standard extenders.
      if ::Ractor.main?
        require "objspace"
        snapshot = {}
        ::ObjectSpace.each_object(::Module) do |mod|
          next unless mod.respond_to?(:registered_middleware) && mod.name
          registry = mod.instance_variable_get(:@registered_middleware)
          next unless registry.is_a?(::Hash)
          shareable = _faraday_shareable_copy(registry)
          snapshot[mod.name] = shareable if shareable
        end
        _reassign_shareable_const(:FARADAY_MW_REGISTRIES, ::Ractor.make_shareable(snapshot))
      end

      ::Faraday::MiddlewareRegistry.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def registered_middleware
          if ::Ractor.main?
            @registered_middleware ||= {}
          else
            key = :"ractor_rails_shim_faraday_mw_\#{name}"
            ::RactorRailsShim.storage[key] ||=
              (::RactorRailsShim::FARADAY_MW_REGISTRIES[name] || {}).dup
            ::RactorRailsShim.storage[key]
          end
        end

        def middleware_mutex(&block)
          if ::Ractor.main?
            @middleware_mutex ||= Monitor.new
            @middleware_mutex.synchronize(&block)
          else
            # No lock needed: the worker's registry copy is Ractor-local.
            yield
          end
        end
      RUBY
    end

    def _install_faraday_default_options
      ::Faraday::Middleware.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_options
          if ::Ractor.main?
            @default_options ||= DEFAULT_OPTIONS.merge(self::DEFAULT_OPTIONS)
          else
            key = :"ractor_rails_shim_faraday_default_options_\#{object_id}"
            value = ::RactorRailsShim.storage[key]
            unless value
              value = ::Faraday::Middleware::DEFAULT_OPTIONS.merge(self::DEFAULT_OPTIONS).freeze
              ::RactorRailsShim.storage[key] = value
            end
            value
          end
        end
      RUBY
    end

    # Options subclass registry: record every subclass at definition time,
    # snapshot its tables at install, then serve worker reads from the
    # shareable registry.
    def _faraday_capture_options_subclass(subclass)
      @faraday_options_subclasses ||= []
      @faraday_options_subclasses << subclass
    end

    def _install_faraday_options_tables
      return unless defined?(::Faraday::Options)
      recorder = ::Module.new do
        def inherited(subclass)
          ::RactorRailsShim._faraday_capture_options_subclass(subclass)
          super
        end
      end
      ::Faraday::Options.singleton_class.prepend(recorder)

      if ::Ractor.main?
        registry = {}
        subclasses = []
        begin
          ObjectSpace.each_object(::Class) do |klass|
            subclasses << klass if klass < ::Faraday::Options
          end
        rescue ::StandardError
          subclasses = (@faraday_options_subclasses || [])
        end
        subclasses.each do |klass|
          memo = klass.instance_variable_get(:@memoized_attributes) rescue nil
          attr_opts = klass.instance_variable_get(:@attribute_options) rescue nil
          memo_sh = memo.is_a?(::Hash) ? _faraday_shareable_copy(memo) : nil
          opts_sh = attr_opts.is_a?(::Hash) ? _faraday_shareable_copy(attr_opts) : nil
          entry = {}
          entry[:memoized] = memo_sh if memo_sh
          entry[:options] = opts_sh if opts_sh
          registry[klass.object_id] = entry unless entry.empty?
        end
        _reassign_shareable_const(:FARADAY_OPTIONS_TABLES, ::Ractor.make_shareable(registry))
      end

      ::Faraday::Options.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def memoized_attributes
          if ::Ractor.main?
            @memoized_attributes ||= {}
          else
            entry = ::RactorRailsShim::FARADAY_OPTIONS_TABLES[object_id]
            (entry && entry[:memoized]) || {}
          end
        end

        def attribute_options
          if ::Ractor.main?
            @attribute_options ||= {}
          else
            entry = ::RactorRailsShim::FARADAY_OPTIONS_TABLES[object_id]
            (entry && entry[:options]) || {}
          end
        end
      RUBY
    end

    def _install_faraday_env_member_set
      return unless defined?(::Faraday::Options::Env)
      ::Faraday::Options::Env.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def member_set
          if ::Ractor.main?
            @member_set ||= Set.new(members)
          else
            key = :ractor_rails_shim_faraday_env_member_set
            ::RactorRailsShim.storage[key] ||= ::Set.new(members).freeze
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_faraday_handler_registry
      ::Faraday::RackBuilder::Handler.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def initialize(klass, *args, **kwargs, &block)
          @name = klass.to_s
          # The shared AdapterRegistry (Monitor + mutable Hash) is only
          # populated from main; workers look the class up directly.
          REGISTRY.set(klass) if ::Ractor.main? && klass.respond_to?(:name)
          @args = args
          @kwargs = kwargs
          @block = block
        end

        def klass
          if ::Ractor.main?
            REGISTRY.get(@name)
          else
            # Plain lookup: the shared AdapterRegistry (Monitor + mutable
            # Hash) must not be read or written from a worker.
            ::Object.const_get(@name)
          end
        end
      RUBY
    end

    # Worker branch for `default_connection_options`: the upstream reader
    # memoizes into the module ivar `@default_connection_options` — workers
    # may never SET module ivars, and `Faraday.new` hits this reader first.
    # Main keeps the original reader (and the ivar-invalidating writer)
    # verbatim; workers memoize a fresh ConnectionOptions per Ractor.
    def _install_faraday_default_connection_options
      ::Faraday.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_default_connection_options, :default_connection_options
        def default_connection_options
          if ::Ractor.main?
            _shim_original_default_connection_options
          else
            key = :ractor_rails_shim_faraday_default_connection_options
            ::RactorRailsShim.storage[key] ||= ::Faraday::ConnectionOptions.new
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_faraday_default_connection
      ::Faraday.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :_shim_original_default_connection, :default_connection
        def default_connection
          if ::Ractor.main?
            _shim_original_default_connection
          else
            key = :ractor_rails_shim_faraday_default_connection
            ::RactorRailsShim.storage[key] ||= ::Faraday::Connection.new(default_connection_options)
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _faraday_shareable_copy(val)
      ::Ractor.make_shareable(val)
      val
    rescue ::StandardError
      begin
        ::RactorRailsShim::ShareabilityTraversal.replace_unshareable_procs!(val)
        ::RactorRailsShim::ShareabilityTraversal.replace_locks_and_concurrent_maps!(val)
        ::Ractor.make_shareable(val)
        val
      rescue ::StandardError
        nil
      end
    end
  end
end
