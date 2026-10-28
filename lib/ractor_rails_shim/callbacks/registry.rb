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
# Transports may additionally implement wrap-style callback phases via
#   around(context, kind, inner) -> inner or a new callable
# `inner` is the rest of the chain as a callable; the transport returns a
# callable that invokes its own `:around` filters and (each calibration point)
# calls `inner` in turn. A transport that does not implement `around` simply
# does not wrap (duck-typing, Open/Closed).
#
# Real Rails around-chain semantics (verified against ActiveSupport): the
# FIRST-declared `:around` filter is OUTERMOST (`a { b { block } }`), the
# after-half runs INSIDE the innermost around's `yield` (block → after → the
# arounds' post-yield code unwinds), and an around filter that never calls
# yield suppresses the block AND the after-half. `replay` reproduces exactly
# that: the after-work lives inside the innermost callable, not outside the
# around chain.
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
        @applicable_cache = {}
      end

      # Register one transport. Returns self for chaining.
      def register(transport)
        @transports << transport
        @applicable_cache.clear
        self
      end

      # The subset of transports that apply to `kind`. Memoized per kind —
      # `replay` asks on every callback run and the transport set is fixed
      # between `register` calls, so the per-call `select` + Array allocation
      # was pure overhead on the hot path. Public so tests (and a future "is
      # anything replayable for this kind?" check) can introspect.
      def applicable(kind)
        applicable = @applicable_cache[kind]
        return applicable if applicable
        applicable = @transports.select { |t| t.applies_to?(kind) }.freeze
        @applicable_cache[kind] = applicable
        applicable
      end

      # Replay the empty callback chain for `context` and `kind`. Runs every
      # applicable transport's before-work, yields the block ONCE, then runs
      # every applicable transport's after-work. Returns the block's result.
      # If nothing applies, just yields (matching the original empty-chain path).
      #
      # Wrap-style phases: if any applicable transport implements `around`,
      # its wrap layers replace the plain yield-position. The callable chain
      # is built inside-out: the innermost callable runs the block and the
      # transports' after-work (so the after-half sits INSIDE the around
      # yield, matching ActiveSupport), then each `around`-ing transport
      # wraps that. An outermost around filter that never invokes `inner`
      # therefore suppresses the block AND the after-work, exactly like a
      # real chain.
      #
      # With multiple around-capable transports the FIRST-registered one's
      # filters sit outermost (reverse traversal) — mirrors chain order since
      # transports are registered chain-segment-first. Today only
      # SymbolicTransport implements `around`.
      #
      # Halting (Rails semantics): a :before filter that returns exactly
      # `false` halts the chain — the block does NOT run and NO after-work
      # or around-layer runs. `replay` returns `false`, which propagates out
      # of `run_callbacks` exactly like a halted real chain. Transports signal
      # this by returning `false` from `before` (a transport that only runs
      # work and has no halt signal returns nil).
      def replay(context, kind, &block)
        applicable = applicable(kind)
        return yield if applicable.empty?
        applicable.each do |t|
          halted = t.before(context, kind)
          return false if halted == false
        end
        body = lambda {
          result = block ? block.call : nil
          applicable.each { |t| t.after(context, kind) }
          result
        }
        applicable.reverse_each do |t|
          body = t.around(context, kind, body) if t.respond_to?(:around)
        end
        body.call
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
