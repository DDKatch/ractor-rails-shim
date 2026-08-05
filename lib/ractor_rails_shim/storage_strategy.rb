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
          fb = RactorRailsShim::SHAREABLE_FALLBACK[key]
          return fb unless fb.nil?
          RactorRailsShim::CLASS_ATTR_VALUES[key] if ::Ractor.main?
        end

        def store(owner, key, value)
          RactorRailsShim.storage[key] = value
          RactorRailsShim::CLASS_ATTR_VALUES[key] = value if ::Ractor.main?
          value
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
            return RactorRailsShim::CLASS_ATTR_VALUES[k] if RactorRailsShim::CLASS_ATTR_VALUES.key?(k)
          end
          missing_default
        end

        def store(owner, key, value)
          suffix = _suffix_from_key(key)
          RactorRailsShim::CLASS_ATTR_VALUES[:"ractor_rails_shim_class_attr_#{owner.object_id}_#{suffix}"] = value
          value
        end
      end
    end
  end

  class << self
    # The active storage strategy (either `StorageStrategy::Ractor` or
    # `StorageStrategy::Thread`). Set once at install time from
    # `RunMode.thread?` (see `Installer`). Defaults to the Ractor strategy
    # before install (the common case).
    attr_accessor :storage_strategy
  end
  # Default: Ractor mode (install overrides to Thread when RunMode.thread?).
  self.storage_strategy = StorageStrategy::Ractor
end