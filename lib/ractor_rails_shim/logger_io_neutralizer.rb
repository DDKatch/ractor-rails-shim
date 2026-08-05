# frozen_string_literal: true

# `RactorRailsShim::LoggerIONeutralizer` — the role object that detaches
# the logger IO from the app graph so `Ractor.make_shareable(app)` doesn't
# freeze the process's real `$stdout`/`$stderr` (extracted from the
# facade god module in Step 22.3, Issue #22; POODR §1 SRP).
#
# Strategy:
#   - replace `app.config.logger` (and any broadcast target reachable
#     from the app) with a frozen, shareable no-op `BroadcastLogger`
#     (no IO);
#   - replace any stray `$stdout`/`$stderr` ivar references with a
#     frozen, shareable `NoOpLogDev`;
#   - re-point the MAIN ractor's `Rails.logger` (the per-Ractor module
#     accessor, NOT in the app graph) at a fresh live `BroadcastLogger`
#     writing to `$stderr` — which is NOT reachable from the frozen app,
#     so it stays mutable. Workers build their own per-Ractor
#     `Rails.logger` in the patched reader, so they're unaffected.
#
# The facade method `_neutralize_logger_io!` delegates to `.call` until
# Issue #31 removes it. The `_swallow` debug funnel and `NoOpLogDev`
# (defined in `patches/callables.rb`) are collaborators reached via the
# `funnel` + `noop_log_dev_class` seams. The defaults are the facade
# lookups (`RactorRailsShim.method(:_swallow)` and
# `RactorRailsShim.singleton_class::NoOpLogDev`) so existing call sites
# keep working; `configure(funnel:, noop_log_dev_class:)` injects
# different collaborators so the role is independently constructible and
# specable without the `RactorRailsShim` god module loaded (Issue #23,
# POODR §2 Dependencies).

module RactorRailsShim
  module LoggerIONeutralizer
    @funnel = nil
    @noop_log_dev_class = nil

    # Inject the collaborators. `funnel` is a callable responding to
    # `call(label) { block }` that runs the block and rescues
    # StandardError (matching `_swallow`). `noop_log_dev_class` is a
    # class responding to `.new` returning a sink object the role will
    # freeze + make shareable. Passing `nil` (or calling
    # `reset_configuration`) restores the facade-lookup defaults.
    def self.configure(funnel: nil, noop_log_dev_class: nil)
      @funnel = funnel
      @noop_log_dev_class = noop_log_dev_class
    end

    # Restore the default (facade-lookup) collaborators. Test seam.
    def self.reset_configuration
      @funnel = nil
      @noop_log_dev_class = nil
    end

    # The active funnel: the injected one if configured, else the
    # facade lookup (`RactorRailsShim.method(:_swallow)`).
    def self.funnel
      @funnel || RactorRailsShim.method(:_swallow)
    end

    # The active NoOpLogDev class: the injected one if configured, else
    # the facade lookup (`RactorRailsShim.singleton_class::NoOpLogDev`).
    def self.noop_log_dev_class
      @noop_log_dev_class || RactorRailsShim.singleton_class.const_get(:NoOpLogDev)
    end

    # Neutralize the logger IO reachable from `app` so the subsequent
    # `Ractor.make_shareable(app)` doesn't freeze the process's real
    # `$stdout`/`$stderr`. Best-effort: failures on individual ivar
    # swaps (e.g. frozen owners) are funneled through `funnel` so
    # `debug=` surfaces them. Returns nil (the mutate is in-place).
    def self.call(app)
      # A frozen, shareable no-op BroadcastLogger (no broadcasts → no
      # IO) to swap in for the app-instance logger graph.
      noop_logger = ::ActiveSupport::BroadcastLogger.new
      noop_logger.freeze
      Ractor.make_shareable(noop_logger)

      # Replace the app-instance logger + any IO reachable from the app
      # graph. Walk ivars + Array/Hash children, tracking seen objects
      # by object_id to avoid cycles.
      seen = {}
      stack = [app]
      until stack.empty?
        o = stack.pop
        next if o.equal?(nil) || seen[o.object_id]
        seen[o.object_id] = true
        begin
          o.instance_variables.each do |iv|
            begin; v = o.instance_variable_get(iv); rescue StandardError; next; end
            if iv == :@logger
              # Replace the app-instance / config logger with the no-op
              # (so the frozen app graph holds no live IO). Best-effort;
              # funnel through `funnel` so a frozen-owner failure is
              # traceable under debug=.
              funnel.call("neutralize logger ivar") do
                o.instance_variable_set(iv, noop_logger)
              end
            elsif v.is_a?(::IO) && (v == $stdout || v == $stderr || v == STDOUT || v == STDERR)
              # Any stray IO reference → a shareable no-op sink, built
              # by the injected `noop_log_dev_class` collaborator.
              sink = noop_log_dev_class.new
              sink.freeze
              Ractor.make_shareable(sink)
              funnel.call("neutralize logger IO ivar") do
                o.instance_variable_set(iv, sink)
              end
            elsif v
              stack << v
            end
          end
        rescue StandardError
          # BasicObject or frozen objects don't support instance_variables
        end
        # Use the shared CONTAINER_WALKERS dispatch table to push children
        # onto the stack (Issue #32 — reuse traversal from
        # ShareabilityTraversal instead of duplicating an is_a? chain).
        walker = ShareabilityTraversal::CONTAINER_WALKERS.find { |klass, _| o.is_a?(klass) }&.last
        if walker
          walker.call(o) { |c, _| stack << c if c }
        elsif ShareabilityTraversal.enumerable_but_not_basic?(o)
          o.each { |e| stack << e if e } rescue nil
        end
      end

      # Re-point the MAIN ractor's Rails.logger at a fresh live logger
      # (not reachable from the frozen app) so main keeps logging after
      # the app is made shareable. `$stderr` is each-Ractor-local and not
      # in the app graph, so it stays mutable. Use the same shape Rails
      # uses (BroadcastLogger broadcasting to a Logger writing $stderr).
      # Guard: the patched `Rails.logger=` (from install_rails_module)
      # calls `super`; a fake `::Rails` module in unit specs has no
      # superclass `logger=`, so rescue NoMethodError there. Against real
      # Rails the `super` succeeds and the rescue is never hit.
      if Ractor.main? && defined?(::Rails)
        begin
          live = ::ActiveSupport::BroadcastLogger.new(::Logger.new($stderr))
          ::Rails.logger = live
        rescue NoMethodError
          # Fake Rails in a unit spec — no superclass logger= to super.
        end
      end
      nil
    end
  end
end