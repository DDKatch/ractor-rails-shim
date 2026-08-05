# frozen_string_literal: true

# Funnel: the debug-aware exception-swallowing role extracted from the
# RactorRailsShim god module (Issue #31, step 31.1d; POODR §1 SRP).
#
# Owns the `swallow(label) { block }` contract: run the block, rescue
# StandardError, emit a labeled $stderr line when `debug?` is true,
# return nil on failure. Used by freeze/shareability paths where
# individual failures are expected (some ivars hold intrinsically
# unshareable values like Procs) but a worker crash on the same value
# later has no visible cause.
#
# `debug?` / `debug=` are the configuration seam. The facade
# `RactorRailsShim.debug?` / `debug=` delegate here so existing specs
# keep passing; role objects (ARModelWalker, LoggerIONeutralizer) reach
# the funnel via `configure(funnel:)`, defaulting to `Funnel.method(:swallow)`.

module RactorRailsShim
  module Funnel
    @debug = nil

    class << self
      # When true, swallowed exceptions are reported to $stderr so a worker
      # Ractor that later crashes on an unshareable value has a traceable
      # cause. Default false (silent, the historical behaviour).
      def debug?
        defined?(@debug) ? @debug : false
      end

      def debug=(value)
        @debug = value
      end

      # Swallow an exception raised by the block, optionally logging it
      # when `debug?` is on. `label` identifies the call site (e.g.
      # "freeze AR ivar Post@column_defaults"). Keep the label short —
      # it's only for grepping. Returns the block's value on success,
      # nil on rescued StandardError.
      def swallow(label)
        yield
      rescue StandardError => e
        warn "[ractor_rails_shim] #{label}: #{e.class}: #{e.message[0, 120]}" if debug?
        nil
      end
    end
  end
end