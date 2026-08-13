# frozen_string_literal: true

# Callbacks::Registry — the coordinator that dispatches callback replay across
# an open set of {Callbacks::Transport} objects (POODR §3 duck-typing, §5
# message-based design, Open/Closed: add a callback *kind* by registering a new
# transport, not by editing a `case kind` branch).
#
# The Registry owns the single `yield` of the real callback-chain body. Each
# applicable transport runs its `before` work, then the block runs once, then
# each runs its `after` work. This lets two transports legitimately share a kind
# (e.g. on `:destroy` both the symbolic `before_destroy` filters AND the
# `dependent:` cascade run) without any transport owning the block.
#
# A transport duck-types to:
#   applies_to?(kind)   -> bool
#   before(context, kind) -> runs before-filter work for that chain kind (no-op ok)
#   after(context, kind)  -> runs after-filter work for that chain kind (no-op ok)
#   install            -> hook into the framework to begin capturing (optional)
#   capture            -> finalize the shareable snapshot (optional)
#
# Both `install` and `capture` are optional; the Registry forwards them and
# ignores any transport that does not respond.

module RactorRailsShim
  module Callbacks
    class Registry
      # transports: an Enumerable of transport objects (duck-typed). Defaults
      # to empty so callers can `register` incrementally.
      def initialize(transports = [])
        @transports = transports.is_a?(Enumerable) ? transports.to_a : Array(transports)
      end

      # Register one transport. Returns self for chaining.
      def register(transport)
        @transports << transport
        self
      end

      # The subset of transports that apply to `kind`. Public so tests (and a
      # future "is anything replayable for this kind?" check) can introspect.
      def applicable(kind)
        @transports.select { |t| t.applies_to?(kind) }
      end

      # Replay the empty callback chain for `context` and `kind`. Runs every
      # applicable transport's before-work, yields the block ONCE, then runs
      # every applicable transport's after-work. Returns the block's result.
      # If nothing applies, just yields (matching the original empty-chain path).
      def replay(context, kind, &block)
        applicable = applicable(kind)
        return yield if applicable.empty?
        applicable.each { |t| t.before(context, kind) }
        result = yield
        applicable.each { |t| t.after(context, kind) }
        result
      end

      # Forward the optional framework-hooking phase to every transport that
      # responds. Idempotent install is each transport's own concern.
      def install
        @transports.each { |t| t.install if t.respond_to?(:install) }
      end

      # Forward the optional finalize-the-snapshot phase to every transport
      # that responds. Called from the main Ractor at prepare time.
      def capture
        @transports.each { |t| t.capture if t.respond_to?(:capture) }
      end
    end
  end
end