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
#   { class_object_id => [ {chain_kind:, phase:, filter:, only:, except:,
#                           if_cond:, unless_cond:, on:, except_on:,
#                           validator_attributes:, validator_options:}, … ] }
# where `chain_kind` is the ActiveSupport::Callbacks chain name (e.g. :save),
# `phase` is :before / :after, and `only`/`except` are nil or frozen Arrays of
# action-name Symbols. Two filter shapes are replayed:
#   - filter: Symbol — a shareable method name, `send`-ed on the context.
#   - filter: String — a validator CLASS NAME (recorded by
#     CallbackCapture.record_declared_validator_callback); a fresh validator
#     is rebuilt from validator_attributes/validator_options and
#     .validate(record) is called. This is what makes worker-side `valid?`
#     run real validations.
# All values are natively shareable.
#
# The transport is duck-typed around `context`:
#   - context.class.ancestors -> Enumerable of class-like objects with object_id
#   - context.class.object_id  -> the key the source is indexed by
#   - context.action_name      -> Symbol or nil (only meaningful for controllers)
#   - context.respond_to?(filter, true) + context.public_send(filter)
#
# `:around` symbolic filters ARE transported (wrap-style): `around(context,
# kind, inner)` collects the matching `:around`-phase Symbol filters and
# returns a callable that invokes each filter method with the rest of the
# chain (`inner.call`) as the block — reproducing ActiveSupport's native
# around semantics (first-declared filter outermost; the method's `yield`
# descends into `inner`). Filters whose method is missing or whose body is an
# un-shareable Proc are skipped fail-safe (the chain continues without them).
# Block-based `:around` filters (lambdas/Procs) are NOT captured at all
# (un-shareable Procs) and are therefore never replayed — same policy as for
# every other Proc filter.

module RactorRailsShim
  module Callbacks
    class SymbolicTransport
      # The callback chain kinds this transport owns by default. Controllers
      # use `:process_action`; models use :save/:create/:update/:destroy and
      # their sub-kinds (:validate — the ActiveModel validations chain —
      # :validation, :commit, :rollback). Filter methods defined
      # via `define_method(&block)` with an un-shareable Proc (e.g. AR's autosave
      # association callbacks) are rescued and skipped so app `def` callbacks
      # still run.
      DEFAULT_KINDS = [
        :process_action,
        :save, :create, :update, :destroy,
        :initialize,
        :validate, :validation, :commit, :rollback
      ].freeze

      # source: a Hash { class_object_id => [entry, …] } as described above, OR a
      # callable returning that Hash, OR a Symbol naming the shareable constant
      # to resolve via const_get (so a worker reads the frozen constant after
      # prepare, not a stale snapshot).
      # kinds: the set of chain kinds this transport owns (default
      # DEFAULT_KINDS, which includes model lifecycle kinds). Unshareable-Proc
      # filters are rescued and skipped automatically.
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
      #
      # Returns `false` (halt signal) when a filter returned exactly `false`
      # (model halt semantics) OR when the context is `performed?` after a
      # filter ran (the ActionController `:process_action` terminator:
      # `terminator: ->(c, _) { c.performed? }` — this is how
      # http_basic_authenticate_with's 401 stops the action: it sets
      # response_body directly and returns truthy). Otherwise returns nil.
      # The Registry honors the signal by skipping the yield and all
      # after-work (skip_after_callbacks_if_terminated: true).
      #
      # A filter defined via `define_method(&block)` with an un-shareable Proc
      # raises "defined with an un-shareable Proc in a different Ractor" when
      # `send`-ed in a worker. ActiveRecord generates such methods for autosave
      # associations (e.g. `autosave_associated_records_for_*`). We SKIP those
      # filters and continue the chain so app-defined `def` callbacks still run.
      def before(context, kind)
        halted = false
        each_applicable_filter(context, kind, :before) do |entry|
          next unless condition_allows?(context, entry)
          next unless validation_context_allows?(context, entry)
          result = invoke_filter(context, entry)
          if result == false || (context.respond_to?(:performed?) && context.performed?)
            halted = true
            break
          end
        rescue RuntimeError => e
          raise e unless unshareable_proc_error?(e)
          # Skip the unshareable-Proc filter; the chain continues.
        end
        false if halted
      end

      # Run the matching :after filters for `kind`, ancestor-first.
      def after(context, kind)
        each_applicable_filter(context, kind, :after) do |entry|
          next unless condition_allows?(context, entry)
          next unless validation_context_allows?(context, entry)
          invoke_filter(context, entry)
        rescue RuntimeError => e
          raise e unless unshareable_proc_error?(e)
        end
      end

      # Wrap-style :around replay. `inner` is the rest of the chain as a
      # callable; the return value is `inner` unchanged when no :around filter
      # applies, otherwise a callable that descends through the filters.
      #
      # Nesting matches ActiveSupport (verified against the real compiled
      # chain): the FIRST-declared :around filter is OUTERMOST — it is entered
      # first and wraps every later layer behind its `yield`. So the entries
      # are collected in chain order (superclass-first, declaration order) and
      # folded INNER-first (reverse iteration).
      #
      # Each wrapper sends the filter method with the descending callable as
      # its block (`context.send(:filter) { inner.call }`); a filter method
      # that never yields therefore suppresses the rest of the chain, and a
      # filter method whose body is an un-shareable Proc (define_method with a
      # main-Ractor block) is skipped fail-safe — the inner chain runs without
      # the wrapper. `respond_to?` guards stale captures (a method removed
      # since declaration), matching #invoke_filter.
      #
      # Halting NOTE: an around filter's return value is NOT treated as a halt
      # signal (the wrapper cannot observe it without wrapping the send, and
      # real around-filter methods virtually always return nil). Halting stays
      # a :before-phase concern, as in the compiled chain.
      def around(context, kind, inner)
        collected = []
        each_applicable_filter(context, kind, :around) do |entry|
          next unless entry[:filter].is_a?(::Symbol)
          next unless condition_allows?(context, entry)
          next unless validation_context_allows?(context, entry)
          collected << entry
        rescue RuntimeError => e
          raise e unless unshareable_proc_error?(e)
          # Skip the unshareable-Proc filter; the chain continues.
        end
        # Fold inner-first: entries arrive chain-order (superclass-first,
        # declaration order) and first-declared must end up OUTERMOST, so
        # wrap from the last entry backwards.
        collected.reverse_each do |entry|
          inner = around_wrapper(context, entry, inner)
        end
        inner
      end

      private

      # Build one wrap layer for `entry` around `inner`. The lambda closes
      # over `context`, the filter Symbol, and the inner callable — all
      # worker-side values, so the layer itself is Ractor-safe.
      #
      # Return-value semantics (verified against the real compiled chain):
      # run_callbacks NEVER propagates an around filter's return value. If
      # the filter yielded, the chain evaluates to the INNER callable's
      # result; if it never yielded (render/redirect-and-stop), the chain
      # evaluates to nil. The wrapper distinguishes "yielded" from "skipped":
      # a missing method or an un-shareable-Proc RuntimeError falls through
      # to `inner.call` (fail-safe skip), propagating the inner result.
      def around_wrapper(context, entry, inner)
        filter = entry[:filter]
        lambda {
          begin
            if context.respond_to?(filter, true)
              yielded = false
              yielded_value = nil
              context.send(filter) { yielded = true; yielded_value = inner.call }
              yielded ? yielded_value : nil
            else
              inner.call
            end
          rescue RuntimeError => e
            raise e unless unshareable_proc_error?(e)
            inner.call
          end
        }
      end

      # Walk the context's class hierarchy, collecting every entry whose
      # chain_kind + phase match, then yield them in Rails' accumulation order:
      # superclass filters BEFORE subclass filters, declaration order preserved
      # within each class. `only`/`except` gate each entry against the context's
      # `action_name` when present.
      def each_applicable_filter(context, kind, phase)
        action = action_name_of(context)
        ancestors = ancestors_of(context)
        # ancestors is instance-class-first; we want superclass-first so
        # superclass filters run before subclass filters (Rails order), but
        # declaration order is preserved within each class (no reversal).
        collected = []
        table = source
        return unless table # no captured table yet → nothing to replay
        ancestors.reverse_each do |klass|
          entries = table[class_id_of(klass)]
          next unless entries
          entries.each do |entry|
            next unless entry[:chain_kind] == kind
            next unless entry[:phase] == phase
            next unless action_constraint_allows?(entry, action)
            collected << entry
          end
        end
        collected.each { |e| yield e }
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

      # Whether an exception is the "un-shareable Proc in a different Ractor"
      # RuntimeError raised by `send`-ing a `define_method(&block)` method
      # cross-Ractor. We match on a substring so the check survives minor
      # wording changes in the Ruby error message.
      def unshareable_proc_error?(error)
        error.message.include?("un-shareable Proc")
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

      # Invoke one captured entry against the context. Two entry shapes:
      #   - Symbolic: entry[:filter] is a method-name Symbol — `send` it on
      #     the context (guarded by respond_to?).
      #   - Validator: entry[:filter] is the validator CLASS NAME (String)
      #     recorded by CallbackCapture.record_declared_validator_callback —
      #     rebuild a fresh validator from the shareable descriptor and call
      #     .validate(record). The validator signals via record.errors (its
      #     return value is ignored — Rails halts the validate chain on
      #     errors, not on filter return values).
      def invoke_filter(context, entry)
        if entry[:filter].is_a?(::String)
          run_validator(context, entry)
        elsif context.respond_to?(entry[:filter], true)
          context.send(entry[:filter])
        end
      end

      # Rebuild a validator from its shareable descriptor and run it against
      # the context (the record). Reconstruction mirrors
      # EachValidator#initialize: :attributes is merged back into a dup of
      # the captured options (EachValidator deletes :attributes on init and
      # requires it to be present; plain Validators have no #attributes — the
      # descriptor records nil for them and no merge happens). A fresh
      # instance per invocation: validators are stateless w.r.t. the record,
      # construction is cheap, and per-Ractor memoization would add a cache
      # for no measurable gain.
      def run_validator(context, entry)
        validator_class = ::Object.const_get(entry[:filter])
        opts = entry[:validator_options]
        opts = opts.dup if opts
        if entry[:validator_attributes] && !entry[:validator_attributes].empty?
          (opts ||= {})[:attributes] = entry[:validator_attributes]
        end
        validator_class.new(opts || {}).validate(context)
        nil
      end

      # Gate `on:` / `except_on:` callbacks by the context's
      # `validation_context` (Rails compiles `on: :create` into an
      # unshareable Proc if:, so the capture records the context Symbols and
      # the transport applies them here). Only meaningful on the
      # :validate/:validation chains, where `valid?(context)` sets the
      # context on the record before the chain runs.
      def validation_context_allows?(context, entry)
        on = entry[:on]
        except_on = entry[:except_on]
        return true if on.nil? && except_on.nil?
        return false unless context.respond_to?(:validation_context)
        ctx = context.validation_context
        ctx_arr = ctx.is_a?(Array) ? ctx : Array(ctx)
        in_on = on.nil? || Array(on).any? { |c| ctx_arr.include?(c) }
        not_except = except_on.nil? || !Array(except_on).any? { |c| ctx_arr.include?(c) }
        in_on && not_except
      rescue StandardError
        # If the context read raises, skip the callback (safer than running
        # it unconditionally).
        false
      end

      # Check Symbol if:/unless: conditions on the callback entry against the
      # context. `if_cond` / `unless_cond` are Symbol method names (or nil).
      # The method is called on the context; truthy = run, falsy = skip.
      # Non-Symbol conditions (lambdas/Procs) are NOT captured (they're
      # unshareable), so nil means "no condition" (always allow).
      def condition_allows?(context, entry)
        if entry[:if_cond]
          return false unless context.respond_to?(entry[:if_cond], true) &&
                              context.send(entry[:if_cond])
        end
        if entry[:unless_cond]
          return false if context.respond_to?(entry[:unless_cond], true) &&
                           context.send(entry[:unless_cond])
        end
        true
      rescue StandardError
        # If the condition method raises, skip the callback (safer than
        # running it unconditionally).
        false
      end
    end
  end
end