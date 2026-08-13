# frozen_string_literal: true

require "set"

# Callbacks::SymbolicTransport — replays captured SYMBOLIC callback filters
# (method-name filters such as `before_save :normalize_title`) for ANY callback
# kind. This is the generic half of "a solution for any callback": a callback
# declared with a Symbol is shareable (the Symbol crosses the Ractor boundary),
# so we capture it at declaration time and re-invoke the method in the worker.
#
# Generalizes the controller-only `:process_action` replay to every kind
# (`:save`, `:create`, `:update`, `:destroy`, `:validation`, `:commit`, …) and
# to both controllers and ActiveRecord models.
#
# Source shape (frozen into SHAREABLE_DECLARED_CALLBACKS by CallbackCapture):
#   { class_object_id => [ {chain_kind:, phase:, filter:, only:, except:}, … ] }
# where `chain_kind` is the ActiveSupport::Callbacks chain name (e.g. :save),
# `phase` is :before / :after, and `only`/`except` are nil or frozen Arrays of
# action-name Symbols. All values are natively shareable.
#
# The transport is duck-typed around `context`:
#   - context.class.ancestors -> Enumerable of class-like objects with object_id
#   - context.class.object_id  -> the key the source is indexed by
#   - context.action_name      -> Symbol or nil (only meaningful for controllers)
#   - context.respond_to?(filter, true) + context.public_send(filter)
#
# `:around` symbolic filters are NOT transported (they must wrap the yield, and
# the Registry owns the single yield). Rails `:around` callbacks are almost
# always lambdas anyway; documented as a known limitation in ARCHITECTURE.md §5c.

module RactorRailsShim
  module Callbacks
    class SymbolicTransport
      # The callback chain kinds this transport owns by default. Controllers use
      # `:process_action`; replaying that kind is safe (controller action methods
      # are plain `def`s). Model lifecycle kinds (:save/:create/:update/…) are
      # intentionally NOT replayed by default: many framework/model methods are
      # defined via `define_method(&block)` with an un-shareable Proc, so invoking
      # them in a worker raises "defined with an un-shareable Proc in a different
      # Ractor". That is a separate frozen-graph limitation tracked as a
      # follow-up transport (see ARCHITECTURE.md §5c). The set is injectable so
      # the generic logic is unit-tested across all kinds.
      DEFAULT_KINDS = [:process_action].freeze

      # source: a Hash { class_object_id => [entry, …] } as described above, OR a
      # callable returning that Hash, OR a Symbol naming the shareable constant
      # to resolve via const_get (so a worker reads the frozen constant after
      # prepare, not a stale snapshot).
      # kinds: the set of chain kinds this transport owns (default
      # DEFAULT_KINDS). Inject a broader set to replay model lifecycle callbacks
      # once the un-shareable-Proc limitation is resolved.
      def initialize(source:, kinds: DEFAULT_KINDS)
        @source = source
        @kinds = kinds.is_a?(::Set) ? kinds : ::Set.new(kinds.to_a)
      end

      def source
        s = @source
        return s.call if s.respond_to?(:call)
        return ::RactorRailsShim.const_get(s) if s.is_a?(::Symbol)
        s
      rescue StandardError
        nil
      end

      # Whether this transport owns `kind`. Configured by `kinds:` so the
      # registry can compose multiple symbolic transports for different kind
      # sets without editing this class (Open/Closed).
      def applies_to?(kind)
        @kinds.include?(kind)
      end

      # Run the matching :before filters for `kind`, ancestor-first, respecting
      # only/except. `respond_to?` guards each send so a stale capture never
      # raises NoMethodError (matches the original controller replay behavior).
      def before(context, kind)
        each_applicable_filter(context, kind, :before) do |entry|
          context.send(entry[:filter]) if context.respond_to?(entry[:filter], true)
        end
      end

      # Run the matching :after filters for `kind`, ancestor-first.
      def after(context, kind)
        each_applicable_filter(context, kind, :after) do |entry|
          context.send(entry[:filter]) if context.respond_to?(entry[:filter], true)
        end
      end

      private

      # Walk the context's class hierarchy (ancestors, instance class first),
      # collecting every entry whose chain_kind + phase match, then yield them
      # in ancestor-first order (superclass before subclass, mirroring Rails'
      # accumulation order). `only`/`except` gate each entry against the
      # context's `action_name` when present.
      def each_applicable_filter(context, kind, phase)
        action = action_name_of(context)
        ancestors = ancestors_of(context)
        # ancestors is instance-class-first; build ancestor-first by reversing
        # after collecting per-class, or collect superclass-first directly.
        collected = []
        table = source
        return unless table # no captured table yet → nothing to replay
        ancestors.each do |klass|
          entries = table[class_id_of(klass)]
          next unless entries
          entries.each do |entry|
            next unless entry[:chain_kind] == kind
            next unless entry[:phase] == phase
            next unless action_constraint_allows?(entry, action)
            collected << entry
          end
        end
        # ancestors as returned by Class#ancestors is instance-class-first; we
        # want the superclass filters to run BEFORE the subclass filters (Rails
        # order), so reverse the per-class accumulation.
        collected.reverse_each { |e| yield e }
      end

      def action_name_of(context)
        action = context.action_name if context.respond_to?(:action_name)
        action = action.to_sym if action
        action
      rescue StandardError
        nil
      end

      def ancestors_of(context)
        klass = context.class
        klass.respond_to?(:ancestors) ? klass.ancestors : [klass]
      end

      def class_id_of(klass)
        klass.object_id
      end

      # only: nil (always), [:a, :b] (only those actions); except: nil (never
      # skip), [:a] (skip those). nil action means "no action context" — only
      # runs if the filter has no :only constraint (i.e. :only is nil).
      def action_constraint_allows?(entry, action)
        only = entry[:only]
        except = entry[:except]
        in_only = only.nil? || (action && only.include?(action))
        not_except = except.nil? || !(action && except.include?(action))
        in_only && not_except
      end
    end
  end
end