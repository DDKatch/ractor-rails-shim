# frozen_string_literal: true

# StorageStrategy role (Issue #15): a composed strategy that replaces the
# `if RactorRailsShim.thread_mode?` branch in `class_attribute.rb` (and later
# the remaining `thread_mode?` branches in `active_support.rb` /
# `installer.rb`).
#
# Two implementations share one contract — `lookup(owner, key, missing_default)`
# and `store(owner, key, value)`:
#
#   * `StorageStrategy::Ractor` — direct `RactorRailsShim.storage` (IES)
#     lookup + `SHAREABLE_FALLBACK` (the former `_class_attr_ractor_methods`
#     reader body).
#   * `StorageStrategy::Thread`  — ancestor-walk + `CLASS_ATTR_VALUES` (the
#     former `_class_attr_thread_methods` reader body). The Thread strategy
#     keys by the receiver's `object_id` tail, so `lookup`/`store` must walk
#     ancestors on read (subclass copy-on-write fallback) and key by
#     `self.object_id` on write.
#
# `class_attribute.rb` emits ONE heredoc that calls
# `RactorRailsShim.storage_strategy.lookup(...)` / `.store(...)` — the two-mode
# branch collapses to a single body. The selected strategy is set once at
# install time from `RunMode.thread?` (see `Installer`).

module RactorRailsShim
  module StorageStrategy
    # Ractor-mode strategy: direct IES lookup + SHAREABLE_FALLBACK. The
    # `key` is a fixed Symbol literal (no per-ancestor interpolation); the
    # writer always targets this owner's single `key`.
    module Ractor
      class << self
        # `missing_default` is a Ruby source string (inlined into the eval'd
        # heredoc by the caller). The Ractor strategy does NOT consult it —
        # its three tiers (IES → SHAREABLE_FALLBACK → CLASS_ATTR_VALUES[main])
        # cover the lookup; the missing_default is accepted for contract
        # parity with the Thread strategy but unused. This matches the former
        # `_class_attr_ractor_methods` reader exactly.
        def lookup(owner, key, missing_default)
          v = RactorRailsShim.storage[key]
          return v if RactorRailsShim.storage.key?(key)
          fb = RactorRailsShim::Registry.shareable_fallback[key]
          return fb unless fb.nil?
          RactorRailsShim::Registry.class_attr_values[key] if ::Ractor.main?
        end

        def store(owner, key, value)
          RactorRailsShim.storage[key] = value
          RactorRailsShim::Registry.class_attr_values[key] = value if ::Ractor.main?
          value
        end

        # Thread mode serves requests in the main Ractor, where the eager-
        # load class_attribute leak corrupts __callbacks, so captured
        # symbolic filters are ALWAYS replayed (ignoring __callbacks).
        def replay_callbacks_always?
          false
        end

        # Ractor mode: replay captured callbacks only when __callbacks is
        # empty (the worker-Ractor case — workers get the empty default).
        # In the main Ractor, __callbacks is live and replay is skipped.
        def replay_callbacks_on_empty?
          !::Ractor.main?
        end
      end
    end

    # Thread-mode strategy: ancestor-walk + CLASS_ATTR_VALUES. The key the
    # caller passes is the FIXED namespaced key (`:"ractor_rails_shim_class_
    # attr_<oid>_<name>"`); the Thread strategy reads via ancestor-walk using
    # each ancestor's `object_id`, and writes keyed by the receiver's
    # `object_id`. The `namespaced_name` suffix is extracted from the key so
    # the ancestor walk can rebuild per-ancestor keys.
    module Thread
      # Extract the `_<namespaced_name>` suffix from a key of the form
      # `:"ractor_rails_shim_class_attr_<oid>_<namespaced_name>"`. The
      # suffix is everything after the second-to-last underscore-group
      # (the object_id is the last numeric group before the suffix).
      def self._suffix_from_key(key)
        # `key` is a Symbol of the form
        # `:"ractor_rails_shim_class_attr_<oid>_<namespaced_name>"`. `to_s`
        # has no leading colon. Strip the fixed prefix + numeric oid + the
        # underscore after it, leaving the namespaced-name suffix.
        key.to_s.sub(/\Aractor_rails_shim_class_attr_\d+_/, "")
      end
      private_class_method :_suffix_from_key

      class << self
        # The missing_default is inlined into the eval'd heredoc by the caller
        # as the actual VALUE (the heredoc interpolates the expression, so the
        # strategy receives the evaluated object, not a source string). The
        # ancestor walk rebuilds each ancestor's key from its object_id + the
        # namespaced suffix.
        def lookup(owner, key, missing_default)
          suffix = _suffix_from_key(key)
          owner.ancestors.each do |anc|
            k = :"ractor_rails_shim_class_attr_#{anc.object_id}_#{suffix}"
            return RactorRailsShim::Registry.class_attr_values[k] if RactorRailsShim::Registry.class_attr_values.key?(k)
          end
          missing_default
        end

        def store(owner, key, value)
          suffix = _suffix_from_key(key)
          RactorRailsShim::Registry.class_attr_values[:"ractor_rails_shim_class_attr_#{owner.object_id}_#{suffix}"] = value
          value
        end

        # Thread mode: the eager-load class_attribute leak corrupts
        # __callbacks, so ALWAYS replay the captured symbolic filters
        # (ignoring __callbacks entirely).
        def replay_callbacks_always?
          true
        end

        # Thread mode always replays, so the on-empty branch is unreachable
        # (the always branch returns first). Provided for contract parity.
        def replay_callbacks_on_empty?
          true
        end
      end
    end
  end

  class << self
    # The active storage strategy (either `StorageStrategy::Ractor` or
    # `StorageStrategy::Thread`). Set once at install time from
    # `RunMode.thread?` (see `Installer`). Can also be set directly by tests.
    # When unset, derives lazily from `RunMode.thread?` so a stale strategy
    # can't leak across tests that reset `RunMode`.
    attr_writer :storage_strategy

    def storage_strategy
      return @storage_strategy if defined?(@storage_strategy)
      RactorRailsShim::RunMode.thread? ? StorageStrategy::Thread : StorageStrategy::Ractor
    end
  end
end