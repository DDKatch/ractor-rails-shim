# frozen_string_literal: true

# Callbacks — the generalized callback-transport layer (POODR §3 duck-typed
# interface, §5 message-based design, Open/Closed). See ARCHITECTURE.md §5c.
#
# This barrel requires the Registry + the two built-in transports and exposes
# `Callbacks.registry`, a per-Ractor Registry wired to the shim's shareable
# callback tables. The storage strategy's `replay_callbacks!` delegates to it
# and the nil-safe `run_callbacks` patch triggers it on an empty chain. Adding a
# new callback *kind* means registering a new transport here — no `if kind ==`
# branches anywhere in the hot path.
#
# Ractor note: the Registry/transport objects are built PER Ractor and memoized
# in Ractor.current (NOT in a class ivar) because (a) class/module ivars set in
# the main Ractor raise IsolationError when a worker reads them, and (b) the
# transports' source is a Symbol (the constant name) resolved via const_get,
# which works in any Ractor — the frozen shareable constants ARE readable
# cross-Ractor even though ivars are not.

require_relative "callbacks/registry"
require_relative "callbacks/symbolic_transport"
require_relative "callbacks/dependent_association_transport"

module RactorRailsShim
  module Callbacks
    # The constant names the built-in transports resolve at replay time.
    DECLARED_CALLBACKS_CONST = :SHAREABLE_DECLARED_CALLBACKS
    DEPENDENT_ASSOCIATIONS_CONST = :SHAREABLE_DEPENDENT_ASSOCIATIONS

    class << self
      # The active Registry for THIS Ractor. Built once per Ractor and cached
      # in Ractor.current (a class ivar would raise IsolationError in workers).
      # Tests may replace it via `registry=` (per-Ractor) to inject fakes.
      def registry
        cache = Ractor.current
        cache[:rrs_callbacks_registry] ||= build_default_registry
      end

      def registry=(value)
        Ractor.current[:rrs_callbacks_registry] = value
      end

      # Forget the cached registry (e.g. after a re-prepare). Per-Ractor.
      def reset_registry
        Ractor.current[:rrs_callbacks_registry] = nil
      end

      # Build a fresh Registry wired to the shim's shareable callback tables.
      # Public so tests/integration can rebuild after a re-prepare. The
      # transports take the CONSTANT NAME (a Symbol) and resolve it themselves
      # via const_get at replay time, so no main-Ractor-bound object crosses the
      # boundary.
      def build_default_registry
        Registry.new([
          SymbolicTransport.new(source: DECLARED_CALLBACKS_CONST),
          DependentAssociationTransport.new(source: DEPENDENT_ASSOCIATIONS_CONST)
        ])
      end
    end
  end
end