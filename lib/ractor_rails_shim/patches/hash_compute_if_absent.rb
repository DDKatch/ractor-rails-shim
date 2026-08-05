# frozen_string_literal: true

# `RactorRailsShim::Patches::HashComputeIfAbsent` — the role object that
# owns the `Hash#compute_if_absent` patch (extracted from the facade god
# module in Step 22.1, Issue #22; POODR §1 SRP).
#
# Background: the shim replaces `Concurrent::Map` instances in the frozen
# app graph with plain `Hash`es (Concurrent::Map is not Ractor-shareable).
# Rails code calls `compute_if_absent` on these caches, so the shim adds a
# compatible method to `Hash`. See `spec/compute_if_absent_spec.rb` for the
# full semantics contract (mutable vs frozen receiver, nil-storing,
# per-Hash isolation via per-Ractor IES keyed by object_id).
#
# This object owns:
#   - the idempotency flag (`@installed`) — it lives here, not on the facade
#   - the `Hash#compute_if_absent` prepend
#
# The facade method `_install_hash_compute_if_absent_patch` delegates to
# `Patches::HashComputeIfAbsent.install` until Issue #31 removes it.

module RactorRailsShim
  module Patches
    module HashComputeIfAbsent
      @installed = false
      @mutex = Mutex.new

      module Overrides
        # Semantics MUST match `Concurrent::Map#compute_if_absent` exactly:
        #   - if the key is present (even with a nil value), return the stored
        #     value WITHOUT invoking the block;
        #   - otherwise invoke the block, STORE the result (including nil), and
        #     return it.
        #
        # The nil-storing behaviour is load-bearing: Concurrent::Map stores
        # nil results so the block doesn't re-run; the original shim
        # implementation used `IES[key] ||= yield` in the frozen branch, which
        # SKIPS nil — a divergent semantics that re-invokes the block on every
        # lookup for any cache slot whose computed value is nil.
        #
        # For a MUTABLE cache the shim freezes the replaced Hash (so it is
        # shareable across workers); mutating it would raise FrozenError. So
        # when the receiver is frozen we route the store to per-Ractor IES
        # keyed by the Hash identity and the key — giving each worker its own
        # cache entry without mutating the shared object. The frozen branch
        # mirrors the mutable one: check presence first (via IES key?),
        # invoke the block only on miss, store the result (including nil)
        # via IES[]=.
        def compute_if_absent(key)
          if frozen?
            # Check the receiver first — a present key (even nil-valued)
            # returns without invoking the block, matching Concurrent::Map.
            return self[key] if key?(key)
            # Per-Ractor IES slot, namespaced by this Hash's object_id so
            # two frozen hashes with the same key don't collide. Use a
            # two-level structure (Hash per receiver) so the presence check
            # (`key?`) and the store share the same slot.
            slot = RactorRailsShim.storage[:rrs_cia] ||= {}
            bucket = slot[object_id] ||= {}
            return bucket[key] if bucket.key?(key)
            bucket[key] = yield(key)
          elsif key?(key)
            self[key]
          else
            self[key] = yield(key)
          end
        end
      end

      # Install the `Hash#compute_if_absent` patch. Idempotent — the
      # `@installed` flag lives on this object, not on the facade.
      # Returns true once installed (and on subsequent no-op calls).
      def self.install
        @mutex.synchronize do
          return true if @installed
          if ::Hash.method_defined?(:compute_if_absent)
            @installed = true
            return true
          end
          ::Hash.prepend(Overrides)
          @installed = true
        end
        true
      end

      # Reader for the idempotency flag. Owned by this role object.
      def self.installed?
        @installed
      end

      # Test seam: reset the idempotency flag between specs. Production
      # code never calls this — the prepend is permanent, but specs that
      # re-run install need a clean slate for assertion purposes.
      def self.reset_installed_for_test!
        @mutex.synchronize { @installed = false }
      end
    end
  end
end