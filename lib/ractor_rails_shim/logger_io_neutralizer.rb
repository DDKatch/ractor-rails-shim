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
# (defined in `patches/callables.rb`) are collaborators reached through
# the facade; Issue #23 will inject them as constructor arguments.

module RactorRailsShim
  module LoggerIONeutralizer
    # Neutralize the logger IO reachable from `app` so the subsequent
    # `Ractor.make_shareable(app)` doesn't freeze the process's real
    # `$stdout`/`$stderr`. Best-effort: failures on individual ivar
    # swaps (e.g. frozen owners) are funneled through `_swallow` so
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
              # funnel through _swallow so a frozen-owner failure is
              # traceable under debug=.
              RactorRailsShim._swallow("neutralize logger ivar") do
                o.instance_variable_set(iv, noop_logger)
              end
            elsif v.is_a?(::IO) && (v == $stdout || v == $stderr || v == STDOUT || v == STDERR)
              # Any stray IO reference → a shareable no-op sink. NoOpLogDev
              # is defined on RactorRailsShim's singleton class (in
              # patches/callables.rb); reach it through the facade.
              sink = RactorRailsShim.singleton_class.const_get(:NoOpLogDev).new
              sink.freeze
              Ractor.make_shareable(sink)
              RactorRailsShim._swallow("neutralize logger IO ivar") do
                o.instance_variable_set(iv, sink)
              end
            elsif v
              stack << v
            end
          end
        rescue StandardError
          # BasicObject or frozen objects don't support instance_variables
        end
        if o.is_a?(Array); o.each { |e| stack << e if e }
        elsif o.is_a?(Hash); o.each { |_, val| stack << val if val }
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