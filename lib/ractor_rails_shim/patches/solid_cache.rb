# frozen_string_literal: true

# Solid Cache worker support (:solid_cache_store under Ractor mode).
#
# With config/cache.yml `database: primary` the store is DB-backed, so a
# worker-side Rails.cache fetch/read hits SolidCache::Entry class methods
# that lazily memoize into CLASS instance variables — which a worker cannot
# write (Ractor::IsolationError: "can not set instance variables of
# classes/modules by non-main Ractors"):
#
#   - Entry.select_sql memoizes per-keys-count SQL in `@select_sql`
#     (app/models/solid_cache/entry.rb, on the read_multi path).
#
# Fix, mirroring the per-Ractor attribute_method_patterns_cache pattern
# (_install_active_model_attribute_method_patterns_patch): re-define the
# singleton method with a main/worker branch. Main keeps the original
# lazy-memo semantics; workers route the memo through Ractor.current
# (per-Ractor storage, shared by the worker's threads). The SQL computation
# is deterministic — a pure function of keys.count — so per-Ractor
# recomputation is correct and no cross-Ractor state is shared.
module RactorRailsShim
  class << self
    def _install_solid_cache_patch
      return if @solid_cache_patched
      @solid_cache_patched = true
      _register_patch :solid_cache, "8.1"
      return unless defined?(::SolidCache::Entry)

      ::SolidCache::Entry.singleton_class.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def select_sql(keys)
          sql = where(key_hash: [1111, 2222])
                  .select(:key, :value)
                  .to_sql
                  .gsub("1111, 2222", ::Array.new(keys.count, "?").join(", "))
          if ::Ractor.main?
            @select_sql ||= {}
            @select_sql[keys.count] ||= sql
          else
            store = ::Ractor.current[:__rrs_solid_cache_select_sql__] ||= {}
            store[keys.count] ||= sql
          end
        end
      RUBY

      # The store's background job pool (`Execution#initialize`:
      # `@background = Concurrent::FixedThreadPool.new(1, max_queue: 100,
      # fallback_policy: :discard)`) is reachable from the frozen graph, so
      # the freeze deep-freezes it (NoOpLocks + frozen @queue). A
      # worker-side cache write that triggers expiry
      # (`Expiry#track_writes` → `Expiry#expire_later` → `Execution#async`
      # → `@background << lambda`) posts to the FROZEN pool —
      #   FrozenError: can't modify frozen Concurrent::FixedThreadPool
      # (@queue is frozen). Give workers their own 1-thread pool through
      # Ractor.current (per-Ractor storage, same seam as the select_sql
      # memo above): async expiry work is per-Ractor and main keeps the
      # upstream pool verbatim. Prepend (no class-variable access, so no
      # "overtaken" concern).
      return unless defined?(::SolidCache::Store::Execution)

      background_pool_module = Module.new do
        private

        def async(&block)
          if ::Ractor.main?
            super
          else
            pool = ::Ractor.current[:__rrs_solid_cache_background__] ||=
              ::Concurrent::FixedThreadPool.new(1, max_queue: 100, fallback_policy: :discard)
            current_shard = ::SolidCache::Entry.current_shard
            pool << ->() do
              __send__(:wrap_in_rails_executor) do
                connections.with(current_shard) do
                  __send__(:setup_instrumentation, &block)
                end
              end
            rescue ::Exception => exception
              error_handler&.call(method: :async, exception: exception, returning: nil)
            end
          end
        end
      end
      ::SolidCache::Store::Execution.prepend(background_pool_module)
    end
  end
end
