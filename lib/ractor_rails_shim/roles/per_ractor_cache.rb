# frozen_string_literal: true

# PerRactorCache: give process-local cache stores one instance per Ractor
# instead of freezing and sharing a single instance.
#
# Why this exists
# ---------------
# `Rails.cache` is registered in CLASS_ATTRIBUTES, so `FallbackBuilder.build!`
# calls `Ractor.make_shareable` on the store at prepare time. Stores that keep
# live data in process memory cannot survive that:
#
#   - `MemoryStore` keeps entries in `@data` and refreshes LRU order with
#     `@data.delete(key)` / `@data[key] = payload` on EVERY read
#     (memory_store.rb `read_entry`). A deep-frozen store therefore raises
#     `FrozenError` on reads and writes alike.
#   - `NullStore` prepends `Strategy::LocalCache`, which lazily memoizes
#     `@local_cache_key` (`@local_cache_key ||= ...`) and raises `FrozenError`
#     on a frozen instance.
#
# Worse, the failed `make_shareable` freezes the LIVE store, so the main
# Ractor breaks too — not just workers.
#
# The fix: swap the store for a same-class proxy that holds only a shareable
# spec (class name + shareable options) and delegates every cache method to a
# Ractor-local instance. The original instance stays unfrozen in the main
# Ractor (boot-warmed entries keep working there).
#
# Stores that are safe to share by reference are NOT wrapped:
#   - Solid Cache: DB-backed; mutable per-call state lives in the database
#     (the shim's solid_cache.rb handles its per-Ractor memos/pool).
#   - FileStore: writes go to disk atomically; the instance holds no mutable
#     hot-path state.
#
# This role is main-Ractor-only for `wrap!` / `swap!`. Workers only call
# `store_for`, which reads the shareable spec off the proxy.

module RactorRailsShim
  module PerRactorCache
    # Stores whose instances hold process-local mutable state (or a
    # non-shareable connection pool) and therefore cannot be shared by
    # reference. Matched by class ancestry, so subclasses are covered.
    #
    # RedisCacheStore / MemCacheStore are listed because sharing a frozen
    # connection pool across Ractors would corrupt it. Neither can be
    # reconstructed from `store.options` (Redis keeps its connection config
    # out of @options; MemCacheStore takes addresses positionally), so
    # `wrap!` leaves them alone and emits a boot warning instead.
    PROCESS_LOCAL = %w[
      ActiveSupport::Cache::MemoryStore
      ActiveSupport::Cache::NullStore
      ActiveSupport::Cache::RedisCacheStore
      ActiveSupport::Cache::MemCacheStore
    ].freeze

    # The subset we can faithfully rebuild from `store.options`.
    # MemoryStore/NullStore take an options Hash; Redis keeps its connection
    # config out of @options and MemCacheStore takes addresses positionally,
    # so rebuilding either would silently point workers at the wrong server.
    WRAPPABLE = %w[
      ActiveSupport::Cache::MemoryStore
      ActiveSupport::Cache::NullStore
    ].freeze

    # Shareable proxy for the current `Rails.cache` store, or nil. Reassigned
    # by `wrap!` before workers spawn; workers read it as a constant.
    PROXY = nil

    # Sentinel for "this option value cannot be made shareable".
    UNSHAREABLE = Object.new
    def UNSHAREABLE.inspect = "#<RactorRailsShim::PerRactorCache::UNSHAREABLE>"
    UNSHAREABLE.freeze

    @main_stores = {}          # spec[:store_id] => original store (main only)
    @wrapped = {}              # store.object_id => proxy (idempotency)
    @delegator_modules = {}    # store class => generated delegator module

    class << self
      # The current proxy (nil when no wrapping happened). Worker-safe: reads
      # a shareable constant, never a module ivar.
      def proxy
        PROXY
      end

      # True when `store` must not be shared by reference.
      def process_local?(store)
        return false if store.nil?
        klass = store.class
        return false unless klass.name
        klass.ancestors.any? { |ancestor| PROCESS_LOCAL.include?(ancestor.name) }
      rescue StandardError
        false
      end

      # Wrap `store` if it is process-local. Returns the proxy, or nil when
      # the store should keep the existing share-by-reference behavior.
      # Must run in the main Ractor before the app graph is frozen.
      def wrap!(store)
        return nil if store.nil?
        return @wrapped[store.object_id] if @wrapped.key?(store.object_id)
        return nil unless process_local?(store)

        spec = spec_for(store)
        unless wrappable?(store) && reconstructible?(store.class, spec[:options])
          warn "ractor-rails-shim: cache store #{store.class.name} cannot be " \
               "reconstructed per Ractor; worker Ractors will share a frozen " \
               "instance. Use :solid_cache_store or :file_store in Ractor mode."
          return nil
        end

        proxy = build_proxy(store.class, spec)
        @main_stores[spec[:store_id]] = store
        @wrapped[store.object_id] = proxy
        ConstReassign.call(self, :PROXY, proxy)
        reassign_rails_cache!(store, proxy)
        proxy
      end

      # Swap `Rails.cache` (and the controller config slot that mirrors it)
      # for a per-Ractor proxy when needed. Idempotent. Main only.
      def swap!
        return nil unless ::Ractor.main?
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application)
        # Only a booted app has a configured cache store. Specs and partial
        # boots that stub `Rails` must not trigger a wrap.
        return nil unless (::Rails.application rescue nil)

        store = ::Rails.cache rescue nil
        return nil if store.nil?

        wrap!(store)
      end

      # The store this Ractor should use for `spec`.
      #
      # Main Ractor: the original instance (keeps boot-warmed entries and any
      # options the spec had to skip).
      # Worker Ractors: one instance per Ractor, memoized in
      # `Ractor.current` (shared by that Ractor's threads, like a forked
      # process's cache).
      def store_for(spec)
        if ::Ractor.main?
          original = @main_stores[spec[:store_id]]
          return original if original
        end

        stores = (::Ractor.current[:__rrs_per_ractor_cache_stores__] ||= {})
        stores[spec[:store_id]] ||= build_store(spec)
      end

      # Build a shareable spec from a live store: class name + the option
      # values that survive `Ractor.make_shareable` (unshareable values such
      # as a Proc namespace are skipped, so the worker instance uses the
      # store's default for that option).
      def spec_for(store)
        options = {}
        ((store.respond_to?(:options) && store.options) || {}).each do |name, value|
          next unless name.is_a?(Symbol) || name.is_a?(String)

          safe = shareable_copy(value)
          if safe.equal?(UNSHAREABLE)
            warn "ractor-rails-shim: cache option #{name.inspect} is not " \
                 "shareable; per-Ractor #{store.class.name} will use its default"
            next
          end
          options[name] = safe
        end

        {
          store_id: store.object_id,
          class_name: store.class.name,
          options: options
        }.tap { |spec| ::Ractor.make_shareable(spec) }
      end

      # Test / re-install seam: forget wrapped stores and the current proxy.
      def reset!
        @main_stores = {}
        @wrapped = {}
        @delegator_modules = {}
        ConstReassign.call(self, :PROXY, nil)
      end

      private

      # True when we know how to rebuild this store class from its options.
      def wrappable?(store)
        store.class.ancestors.any? { |ancestor| WRAPPABLE.include?(ancestor.name) }
      rescue StandardError
        false
      end

      # Deep-copy `value` into a shareable twin, or UNSHAREABLE.
      def shareable_copy(value)
        return value if value.nil? || value == true || value == false ||
          value.is_a?(Symbol) || value.is_a?(Numeric) ||
          value.is_a?(Module)

        copy = begin
          value.dup
        rescue StandardError, TypeError
          return UNSHAREABLE
        end
        ::Ractor.make_shareable(copy)
        copy
      rescue StandardError, ::Ractor::Error
        UNSHAREABLE
      end

      # Can `klass.new(**options)` reproduce the store? FileStore needs a
      # positional path, so it is never process-local-checked here; Redis
      # and MemCacheStore are excluded by `wrappable?`.
      def reconstructible?(klass, options)
        klass.new(**options.dup)
        true
      rescue StandardError, ::Ractor::Error
        false
      end

      # A same-class instance that holds only the spec and delegates the
      # cache API to `store_for`. `klass.allocate` keeps `class` / `is_a?`
      # exact; the singleton prepend confines the delegation to this object.
      def build_proxy(klass, spec)
        proxy = klass.allocate
        proxy.instance_variable_set(:@__rrs_cache_spec__, spec)
        proxy.singleton_class.prepend(delegator_for(klass))
        ::Ractor.make_shareable(proxy)
        proxy
      end

      # Generate `def <name>(*args, **kwargs, &block)` delegators for the
      # store's public API. `def` (not define_method) keeps the module free
      # of block bindings, so it is shareable.
      def delegator_for(klass)
        @delegator_modules[klass] ||= begin
          methods = klass.public_instance_methods - ::Object.public_instance_methods
          mod = Module.new
          methods.sort.each do |name|
            name = name.to_s
            next unless name.match?(/\A[a-z_][a-zA-Z0-9_]*[?!=]?\z/)

            body =
              if name.end_with?("=")
                "def #{name}(value); " \
                  "RactorRailsShim::PerRactorCache.store_for(@__rrs_cache_spec__)" \
                  ".#{name}(value); end"
              else
                "def #{name}(*args, **kwargs, &block); " \
                  "RactorRailsShim::PerRactorCache.store_for(@__rrs_cache_spec__)" \
                  ".__send__(#{name.inspect}, *args, **kwargs, &block); end"
              end
            mod.module_eval(body, __FILE__, __LINE__)
          end
          mod
        end
      end

      # Point `Rails.cache` and `ActionController::Base.config.cache_store`
      # at the proxy. Both mirror the same object in a stock Rails app; the
      # identity check keeps a deliberately different controller store
      # untouched.
      def reassign_rails_cache!(store, proxy)
        if defined?(::Rails) && ::Rails.respond_to?(:cache)
          current = ::Rails.cache rescue nil
          ::Rails.cache = proxy if current.equal?(store)
        end

        return unless defined?(::ActionController::Base)

        config = ::ActionController::Base.config rescue nil
        return unless config && config.respond_to?(:cache_store)

        current = config.cache_store rescue nil
        config.cache_store = proxy if current.equal?(store)
      end

      def build_store(spec)
        klass = ::Object.const_get(spec[:class_name])
        begin
          klass.new(**spec[:options].dup)
        rescue ArgumentError
          # A subclass with a stricter initializer: build with defaults
          # rather than fail every cache call in the worker.
          klass.new
        end
      end
    end
  end
end
