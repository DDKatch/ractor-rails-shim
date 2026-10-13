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
    end
  end
end
