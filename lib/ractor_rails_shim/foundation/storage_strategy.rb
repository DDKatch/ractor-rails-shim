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
    # Literal key for the per-receiver class_attribute storage-key cache,
    # stored in ractor-local IES (IsolatedExecutionState) so each Ractor
    # carries its own copy (no cross-ractor shareability concern — and class
    # variables are illegal from non-main Ractors).
    CA_KEY_CACHE_KEY = :"__ractor_rails_shim_ca_key_cache__"

    # Per-receiver class_attribute storage-key cache. Maps
    # `(attribute-symbol, receiver-object_id) -> storage-key-symbol` so the
    # hot reader path does NOT re-build a `:"..."` interpolated key on every
    # read (which allocated ~2 strings/symbols per read). The key is derived
    # once per (attribute, class) and memoized in ractor-local IES. After the
    # first (warm-up) read for a class, all subsequent reads hit the cache
    # with zero allocation.
    def self.ca_key(owner, attr_sym)
      oid = (owner.is_a?(Module) ? owner : owner.class).object_id
      cache = RactorRailsShim.storage[CA_KEY_CACHE_KEY]
      unless cache
        cache = {}
        RactorRailsShim.storage[CA_KEY_CACHE_KEY] = cache
      end
      inner = cache[attr_sym]
      unless inner
        inner = {}
        cache[attr_sym] = inner
      end
      kkey = inner[oid]
      unless kkey
        kkey = :"ractor_rails_shim_class_attr_#{oid}_#{attr_sym}"
        inner[oid] = kkey
      end
      kkey
    end

    # Rector-mode strategy. Two reader/writer entry points:
    #
    #   * `lookup` / `store`        — EXACT-key 3-tier passthrough. Used by
    #                                IESAccessor (and anything that hands over
    #                                a fully-qualified storage key). No ancestor
    #                                walk; the caller owns the key.
    #   * `lookup_by_attr` / `store_by_attr` — per-receiver class_attribute
    #                                semantics: derive a storage key from the
    #                                receiver's class + the attribute name, then
    #                                walk the ancestor chain so each class keeps
    #                                its OWN class_attribute value (siblings no
    #                                longer clobber each other). Backed by the
    #                                Ractor backends (IES + SHAREABLE_FALLBACK
    #                                + CLASS_ATTR_VALUES[main]).
    module Ractor
      class << self
        # Exact-key 3-tier passthrough (IES → SHAREABLE_FALLBACK →
        # CLASS_ATTR_VALUES[main]). Contract: `key` IS the storage key.
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

        # Per-receiver class_attribute lookup: derive the receiver's storage
        # key (memoized via `StorageStrategy.ca_key`) and walk ancestors so
        # subclasses inherit parent values while keeping their own overrides.
        # `ancestors` (not `superclass`) is required so module-declared
        # class_attributes (e.g. `AbstractController::Callbacks#__callbacks`)
        # are reachable — `superclass` skips included modules.
        #
        # Per-ancestor tier order:
        #   1. `storage` (IES)        — current execution context's override
        #                               (workers set their own value here).
        #   2. `shareable_fallback`   — frozen shareable table built at
        #                               prepare_for_ractors! (worker reads).
        #   3. `class_attr_values`    — the persistent seed registry (main
        #                               only). IES is execution-context
        #                               ISOLATED, so a seed written during
        #                               boot is invisible in a later context;
        #                               `class_attr_values` is a plain Hash
        #                               that survives across contexts, so it
        #                               MUST be consulted per-ancestor (not
        #                               just for the final receiver) — otherwise
        #                               inherited values (e.g. a parent's
        #                               `__callbacks`) are missed.
        def lookup_by_attr(owner, attr_sym, missing_default)
          klass = owner.is_a?(Module) ? owner : owner.class
          klass.ancestors.each do |anc|
            kkey = RactorRailsShim::StorageStrategy.ca_key(anc, attr_sym)
            v = RactorRailsShim.storage[kkey]
            return v if RactorRailsShim.storage.key?(kkey)
            fb = RactorRailsShim::Registry.shareable_fallback[kkey]
            return fb unless fb.nil?
            if ::Ractor.main?
              cv = RactorRailsShim::Registry.class_attr_values[kkey]
              return cv unless cv.nil?
            end
          end
          missing_default
        end

        def store_by_attr(owner, attr_sym, value)
          kkey = RactorRailsShim::StorageStrategy.ca_key(owner, attr_sym)
          RactorRailsShim.storage[kkey] = value
          RactorRailsShim::Registry.class_attr_values[kkey] = value if ::Ractor.main?
          value
        end

        # Zero-allocation hot reader. `resolved_key` is a literal symbol baked
        # into the generated reader method (see `_class_attr_methods`). The
        # first read for a receiver resolves via `lookup_by_attr` (ancestor
        # walk) and caches the result in ractor-local IES keyed by receiver
        # object_id; every subsequent read is a literal-key Hash lookup +
        # integer index — no Array/`ancestors` allocation.
        def lookup_resolved(owner, attr_sym, missing_default, resolved_key)
          klass = owner.is_a?(Module) ? owner : owner.class
          oid = klass.object_id
          cache = RactorRailsShim.storage[resolved_key]
          return cache[oid] if cache && cache.key?(oid)
          v = lookup_by_attr(owner, attr_sym, missing_default)
          cache = RactorRailsShim.storage[resolved_key]
          cache ||= (RactorRailsShim.storage[resolved_key] = {})
          cache[oid] = v
          v
        end

        # Zero-allocation hot writer. Writes the per-receiver slot (so the
        # ancestor-walk `lookup_by_attr` stays correct) AND updates the resolved
        # cache for this receiver so the next read is hot.
        def store_resolved(owner, attr_sym, value, resolved_key)
          kkey = RactorRailsShim::StorageStrategy.ca_key(owner, attr_sym)
          RactorRailsShim.storage[kkey] = value
          RactorRailsShim::Registry.class_attr_values[kkey] = value if ::Ractor.main?
          klass = owner.is_a?(Module) ? owner : owner.class
          oid = klass.object_id
          cache = RactorRailsShim.storage[resolved_key]
          cache ||= (RactorRailsShim.storage[resolved_key] = {})
          cache[oid] = value
          value
        end

        # Ractor mode: replay captured callbacks only when __callbacks is
        # empty (the worker-Ractor case — workers get the empty default).
        # In the main Ractor, __callbacks is live and replay is skipped.
        def replay_callbacks?(callbacks)
          callbacks.nil? || callbacks.empty?
        end

        # Shared callback-replay logic used by both the "always" path
        # (Thread mode) and the "on-empty" path (Ractor mode). Walks the
        # SHAREABLE_DECLARED_CALLBACKS table and replays captured symbolic
        # filters (before/after) that apply to the current action.
        def replay_callbacks!(context, kind, &block)
          if kind == :destroy
            return replay_destroy_dependents!(context) { (yield if block_given?) }
          end
          table = ::RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS
          action = (context.action_name rescue nil)
          action = action.to_sym if action
          entries = []
          k = context.class
          while k && k <= ::ActionController::Base
            rec = table[k.object_id]
            entries = rec + entries if rec
            k = k.superclass
          end
          unless entries.empty?
            applies = lambda do |e|
              next false unless (e[:kind] == :before || e[:kind] == :after)
              in_only = e[:only].nil? || (action && e[:only].include?(action))
              not_except = e[:except].nil? || !(action && e[:except].include?(action))
              in_only && not_except
            end
            result = nil
            halted = false
            entries.each do |e|
              next unless e[:kind] == :before && applies.call(e)
              context.send(e[:filter]) if context.respond_to?(e[:filter], true)
            end
            result = block.call unless halted
            entries.each do |e|
              next unless e[:kind] == :after && applies.call(e)
              context.send(e[:filter]) if context.respond_to?(e[:filter], true)
            end
            result
          else
            block.call
          end
        end

        # Re-drive `dependent:` association cascades for a record being
        # destroyed inside a worker Ractor. The Rails `dependent:` option
        # registers a LAMBDA `before_destroy` filter that workers can't hold
        # (un-shareable Proc), so the shared, frozen model has an EMPTY
        # `:destroy` callback chain. Instead we recorded the dependency table at
        # prepare time (SHAREABLE_DEPENDENT_ASSOCIATIONS) and invoke the exact
        # method the original lambda called: `record.association(name)
        # .handle_dependency`. That dispatches on `:dependent`'s type the same
        # as Rails would (:destroy deletes children, :delete deletes rows,
        # :nullify sets FK null, :restrict_* raises if children remain). Called
        # BEFORE the record itself is deleted, matching the before_destroy order.
        def replay_destroy_dependents!(record, &block)
          table = ::RactorRailsShim::SHAREABLE_DEPENDENT_ASSOCIATIONS
          if table && record.is_a?(::ActiveRecord::Base)
            if (entries = table[record.class.name])
              entries.each do |e|
                assoc = record.association(e[:name])
                assoc.handle_dependency if assoc.respond_to?(:handle_dependency)
              end
            end
          end
          block.call
        end
      end
    end

    # Thread-mode strategy. Mirrors the Ractor module's two entry points:
    #   * `lookup` / `store`        — exact-key passthrough on
    #                                CLASS_ATTR_VALUES (the Thread backend),
    #                                for IESAccessor.
    #   * `lookup_by_attr` / `store_by_attr` — per-receiver class_attribute
    #                                semantics (ancestor-walk on
    #                                CLASS_ATTR_VALUES) so each class keeps its
    #                                own value.
    module Thread
      class << self
        # Exact-key passthrough on CLASS_ATTR_VALUES (the Thread backend).
        def lookup(owner, key, missing_default)
          RactorRailsShim::Registry.class_attr_values[key]
        end

        def store(owner, key, value)
          RactorRailsShim::Registry.class_attr_values[key] = value
          value
        end

        # Per-receiver class_attribute lookup: derive the receiver's storage
        # key (memoized via `StorageStrategy.ca_key`) and walk ancestors on
        # CLASS_ATTR_VALUES.
        def lookup_by_attr(owner, attr_sym, missing_default)
          klass = owner.is_a?(Module) ? owner : owner.class
          klass.ancestors.each do |anc|
            k = RactorRailsShim::StorageStrategy.ca_key(anc, attr_sym)
            return RactorRailsShim::Registry.class_attr_values[k] if RactorRailsShim::Registry.class_attr_values.key?(k)
          end
          missing_default
        end

        def store_by_attr(owner, attr_sym, value)
          klass = owner.is_a?(Module) ? owner : owner.class
          RactorRailsShim::Registry.class_attr_values[RactorRailsShim::StorageStrategy.ca_key(klass, attr_sym)] = value
          value
        end

        # Zero-allocation hot reader (see Ractor#lookup_resolved). Uses the
        # Thread backend (CLASS_ATTR_VALUES) for the resolved cache.
        def lookup_resolved(owner, attr_sym, missing_default, resolved_key)
          klass = owner.is_a?(Module) ? owner : owner.class
          oid = klass.object_id
          cache = RactorRailsShim::Registry.class_attr_values[resolved_key]
          return cache[oid] if cache && cache.key?(oid)
          v = lookup_by_attr(owner, attr_sym, missing_default)
          cache = RactorRailsShim::Registry.class_attr_values[resolved_key]
          cache ||= (RactorRailsShim::Registry.class_attr_values[resolved_key] = {})
          cache[oid] = v
          v
        end

        # Zero-allocation hot writer (see Ractor#store_resolved).
        def store_resolved(owner, attr_sym, value, resolved_key)
          kkey = RactorRailsShim::StorageStrategy.ca_key(owner, attr_sym)
          RactorRailsShim::Registry.class_attr_values[kkey] = value
          klass = owner.is_a?(Module) ? owner : owner.class
          oid = klass.object_id
          cache = RactorRailsShim::Registry.class_attr_values[resolved_key]
          cache ||= (RactorRailsShim::Registry.class_attr_values[resolved_key] = {})
          cache[oid] = value
          value
        end

        # Thread mode: the eager-load class_attribute leak corrupts
        # __callbacks, so ALWAYS replay the captured symbolic filters
        # (ignoring __callbacks entirely). The "on-empty" gate is
        # unreachable (the "always" path runs first); provided for
        # contract parity.
        def replay_callbacks?(callbacks)
          false
        end

        # Thread mode always replays captured callbacks. Delegates to
        # the shared replay_callbacks! implementation on the Ractor
        # strategy (same logic, different trigger).
        def replay_callbacks!(context, kind, &block)
          RactorRailsShim::StorageStrategy::Ractor.replay_callbacks!(context, kind, &block)
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