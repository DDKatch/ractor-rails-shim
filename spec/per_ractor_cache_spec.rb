# frozen_string_literal: true

# Regression spec: worker Ractors could not use process-local cache stores.
#
# `Rails.cache` is registered in CLASS_ATTRIBUTES, so `FallbackBuilder.build!`
# calls `Ractor.make_shareable` on the store at prepare time. Two store
# families cannot survive that:
#
#   - MemoryStore refreshes LRU order on EVERY read (`@data.delete(key)` then
#     `@data[key] = payload`, memory_store.rb#read_entry), so a deep-frozen
#     store raises FrozenError on reads and writes.
#   - NullStore prepends Strategy::LocalCache, which lazily memoizes
#     `@local_cache_key` (`@local_cache_key ||= ...`) on a frozen instance.
#
# Worse, the failed make_shareable freezes the LIVE store object, so the main
# Ractor broke too — not only workers.
#
# PerRactorCache swaps such a store for a same-class shareable proxy that
# delegates to a Ractor-local instance. Stores that are safe to share by
# reference (Solid Cache, FileStore) must stay unwrapped.

require "minitest/autorun"
require "tmpdir"
require "active_support"
require "active_support/cache"
require_relative "../lib/ractor_rails_shim/patches"

class PerRactorCacheSpec < Minitest::Spec
  def setup
    # The patches a real boot applies (order-independent: the cache cattr
    # patch re-routes Store.logger even when cache.rb loaded first, which is
    # the case under `rake spec` because other specs require it early).
    RactorRailsShim.install_mattr_accessor
    RactorRailsShim._install_cache_store_cattr_patch
    RactorRailsShim._install_notifications_notifier_patch
    RactorRailsShim._install_inflector_patch
    # Mirror prepare_for_ractors!'s constant pass: cache calls read
    # OPTION_ALIASES, the Coder templates, SERIALIZERS, and (via
    # Notifications) Concurrent::NULL.
    RactorRailsShim::SHAREABLE_CONSTANTS.each do |path|
      RactorRailsShim.make_constant_shareable!(path)
    rescue StandardError
      nil
    end
    RactorRailsShim._warm_cache_serializer_fallbacks!
    RactorRailsShim::PerRactorCache.reset!
  end

  def teardown
    RactorRailsShim::PerRactorCache.reset!
  end

  def spec_on(proxy)
    proxy.instance_variable_get(:@__rrs_cache_spec__)
  end

  it "classifies MemoryStore/NullStore as process-local and FileStore as shareable" do
    cache = RactorRailsShim::PerRactorCache

    assert cache.process_local?(ActiveSupport::Cache::MemoryStore.new),
           "MemoryStore keeps entries in a mutable Hash — it cannot be shared"
    assert cache.process_local?(ActiveSupport::Cache::NullStore.new),
           "NullStore memoizes LocalCache state on the instance"
    Dir.mktmpdir do |dir|
      refute cache.process_local?(ActiveSupport::Cache::FileStore.new(dir)),
             "FileStore writes to disk and is safe to share by reference"
    end
  end

  it "wraps a MemoryStore in a same-class shareable proxy" do
    store = ActiveSupport::Cache::MemoryStore.new
    proxy = RactorRailsShim::PerRactorCache.wrap!(store)

    refute_same store, proxy
    assert_instance_of ActiveSupport::Cache::MemoryStore, proxy,
                       "the proxy must keep the store's class identity"
    assert Ractor.shareable?(proxy), "the proxy must be readable from every Ractor"
    assert_same proxy, RactorRailsShim::PerRactorCache::PROXY
    assert_same proxy, RactorRailsShim::PerRactorCache.wrap!(store),
                "wrap! must be idempotent"
  end

  it "keeps the original store unfrozen for the main Ractor" do
    store = ActiveSupport::Cache::MemoryStore.new
    store.write("boot", "value")
    proxy = RactorRailsShim::PerRactorCache.wrap!(store)

    assert_same store, RactorRailsShim::PerRactorCache.store_for(spec_on(proxy)),
                "main must keep using the original (boot-warmed) instance"
    refute store.frozen?, "the live main-Ractor store must NOT be frozen"
    assert_equal "value", proxy.read("boot")
  end

  it "serves write/read/fetch from a worker Ractor" do
    proxy = RactorRailsShim::PerRactorCache.wrap!(ActiveSupport::Cache::MemoryStore.new)

    result = Ractor.new(proxy) do |p|
      p.write("k", "v")
      [p.read("k"), p.read("missing"), p.exist?("k"), p.fetch("flag") { "computed" }]
    end.value

    assert_equal ["v", nil, true, "computed"], result
  end

  it "gives each Ractor its own store (no cross-Ractor leakage)" do
    proxy = RactorRailsShim::PerRactorCache.wrap!(ActiveSupport::Cache::MemoryStore.new)

    writer = Ractor.new(proxy) do |p|
      p.write("shared", 1)
      p.read("shared")
    end
    assert_equal 1, writer.value

    reader = Ractor.new(proxy) { |p| p.read("shared") }
    assert_nil reader.value, "worker caches must be per-Ractor, like forked processes"
  end

  it "wraps NullStore (LocalCache memoization used to raise FrozenError)" do
    proxy = RactorRailsShim::PerRactorCache.wrap!(ActiveSupport::Cache::NullStore.new)

    assert_instance_of ActiveSupport::Cache::NullStore, proxy
    write, read, fetched = Ractor.new(proxy) do |p|
      [p.write("k", 1), p.read("k"), p.fetch("k") { 42 }]
    end.value

    assert_equal [true, nil, 42], [write, read, fetched]
  end

  it "leaves share-by-reference stores unwrapped" do
    Dir.mktmpdir do |dir|
      store = ActiveSupport::Cache::FileStore.new(dir)

      assert_nil RactorRailsShim::PerRactorCache.wrap!(store),
                 "FileStore must keep the existing share-by-reference behavior"
      assert_nil RactorRailsShim::PerRactorCache::PROXY

      proxy = RactorRailsShim::PerRactorCache.wrap!(ActiveSupport::Cache::MemoryStore.new)
      assert_nil RactorRailsShim::PerRactorCache.wrap!(ActiveSupport::Cache::FileStore.new(dir)),
                 "a later process-local wrap must not swallow FileStore"
      refute_nil proxy
    end
  end
end
