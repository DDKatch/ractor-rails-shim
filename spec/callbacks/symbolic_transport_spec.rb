# frozen_string_literal: true

# TDD specs for SymbolicTransport — the transport that replays captured
# SYMBOLIC callback filters (method-name filters like `before_save
# :normalize_title`) for ANY callback kind. This generalizes the controller
# `:process_action`-only replay to every kind (save/create/update/destroy/…),
# which is the core of "a solution for any callback".
#
# The transport is duck-typed around two collaborators injected for testability
# (POODR §2 — inject dependencies of the abstractions you own):
#   - source:  a Hash { class_object_id => [ {kind:, filter:, only:, except:}, … ] }
#              (the shape CallbackCapture freezes into SHAREABLE_DECLARED_CALLBACKS)
#   - context: responds to `class` (returning an object with `ancestors` and
#              `object_id`) and to the filter method names via `public_send`
#
# Run: bundle exec ruby -Ilib -Ispec spec/callbacks/symbolic_transport_spec.rb

require "minitest/autorun"
require_relative "../../lib/ractor_rails_shim/callbacks/symbolic_transport"

class SymbolicTransportSpec < Minitest::Spec
  # A fake class object: has an object_id and an ancestors list (for the
  # ancestor walk the transport performs). Cheap stand-in for a real Class.
  class FakeKlass
    attr_reader :object_id, :ancestors
    def initialize(object_id, ancestors)
      @object_id = object_id
      @ancestors = ancestors
    end
  end

  # A fake context: records every filter invocation and exposes a `class`
  # that returns a FakeKlass. `respond_to_missing?` + `method_missing` make any
  # Symbol filter name both `respond_to?`-true and invocable, so the transport's
  # `respond_to?(filter, true)` guard passes and the call is recorded. `action_name`
  # is defined explicitly (returns nil) so the transport reading it does not
  # itself record an invocation; individual tests override it via a singleton def.
  class FakeContext
    attr_reader :invoked, :klass
    # Written by replayed validator entries (`run_validator` does
    # `record.validated_by ||= []`); defined explicitly so the read/write
    # does not route through method_missing.
    attr_accessor :validated_by

    def initialize(klass)
      @klass = klass
      @invoked = []
    end

    def class
      @klass
    end

    def action_name
      nil
    end

    # `performed?` is defined explicitly (returns false) so the transport's
    # ActionController terminator check (`performed?` after each filter) does
    # not itself record an invocation or spuriously halt via the truthy
    # `:sent` method_missing return; halting tests override it in subclasses.
    def performed?
      false
    end

    def respond_to_missing?(name, include_private = false)
      true
    end

    def method_missing(name, *args, &block)
      @invoked << name
      :sent
    end

    def send(name, *args, &block)
      method_missing(name, *args, &block)
    end

    # `send` is the dispatch path the real transport uses; some Rubies also
    # route through `__send__`, so override both to record.
    def __send__(name, *args, &block)
      method_missing(name, *args, &block)
    end
  end

  # A strict context that only responds to methods it explicitly defines — used
  # to verify the transport's `respond_to?` guard skips filters the context does
  # not actually implement (a stale capture should never NoMethodError).
  class StrictContext < FakeContext
    def respond_to?(name, include_private = false)
      return false if name == :no_such_method
      super
    end
  end

  def build_context(ancestor_chain, source)
    # ancestor_chain: array of object_ids from the instance class up to root.
    klasses = ancestor_chain.map { |oid| FakeKlass.new(oid, []) }
    # Wire ancestors so each FakeKlass points at the rest of the chain.
    klasses.each_with_index do |k, i|
      k.instance_variable_set(:@ancestors, klasses[i..])
    end
    FakeContext.new(klasses.first)
  end

  # Build only the FakeKlass chain (shared by FakeContext and StrictContext).
  def build_klass_chain(ancestor_chain)
    klasses = ancestor_chain.map { |oid| FakeKlass.new(oid, []) }
    klasses.each_with_index do |k, i|
      k.instance_variable_set(:@ancestors, klasses[i..])
    end
    klasses.first
  end

  it "applies to every kind it is configured for (generic symbolic transport)" do
    kinds = %i[process_action save create update destroy validation commit rollback]
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: {}, kinds: kinds)
    kinds.each do |k|
      assert t.applies_to?(k), "SymbolicTransport should apply to #{k}"
    end
    # A kind NOT in the configured set is not owned by this transport.
    refute t.applies_to?(:some_other_kind)
  end

  it "defaults to owning process_action + model lifecycle kinds" do
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: {})
    assert t.applies_to?(:process_action)
    assert t.applies_to?(:save)
    assert t.applies_to?(:create)
    assert t.applies_to?(:destroy)
    assert t.applies_to?(:commit)
    refute t.applies_to?(:some_other_kind)
  end

  it "invokes before filters for the matching kind, walking ancestors" do
    # Two classes in the chain: the instance class (oid 10) and its parent (oid 20).
    # The parent declares a before filter; the child does not. Replay must walk up
    # and find the parent's declaration.
    source = {
      20 => [{ chain_kind: :save, phase: :before, filter: :parent_hook, only: nil, except: nil }]
    }
    ctx = build_context([10, 20], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    assert_includes ctx.invoked, :parent_hook
  end

  it "invokes after filters in after-phase, not before-phase" do
    source = {
      10 => [{ chain_kind: :save, phase: :after, filter: :after_hook, only: nil, except: nil }]
    }
    ctx = build_context([10], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    assert_empty ctx.invoked, "after filters must not run in before-phase"
    t.after(ctx, :save)
    assert_includes ctx.invoked, :after_hook
  end

  it "respects :only constraints (filter runs only for matching action)" do
    source = {
      10 => [{ chain_kind: :process_action, phase: :before, filter: :only_index, only: [:index].freeze, except: nil }]
    }
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)

    matching = build_context([10], source)
    def matching.action_name; :index; end
    t.before(matching, :process_action)
    assert_includes matching.invoked, :only_index

    skipped = build_context([10], source)
    def skipped.action_name; :show; end
    t.before(skipped, :process_action)
    refute_includes skipped.invoked, :only_index
  end

  it "respects :except constraints" do
    source = {
      10 => [{ chain_kind: :process_action, phase: :before, filter: :except_show, only: nil, except: [:show].freeze }]
    }
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)

    skipped = build_context([10], source)
    def skipped.action_name; :show; end
    t.before(skipped, :process_action)
    refute_includes skipped.invoked, :except_show

    run = build_context([10], source)
    def run.action_name; :index; end
    t.before(run, :process_action)
    assert_includes run.invoked, :except_show
  end

  it "skips filters whose method is undefined on the context (respond_to? guard)" do
    source = {
      10 => [{ chain_kind: :save, phase: :before, filter: :no_such_method, only: nil, except: nil }]
    }
    # StrictContext reports :no_such_method as unimplemented, so the transport's
    # respond_to? guard must skip it instead of calling method_missing.
    ctx = StrictContext.new(build_klass_chain([10]))
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    refute_includes ctx.invoked, :no_such_method
  end

  it "runs before filters in declaration order (ancestors-first, like Rails)" do
    # Child(10) declares :child_hook; Parent(20) declares :parent_hook.
    # Rails accumulates superclass filters before subclass ones; replay walks
    # ancestors from the instance class UP, prepending so superclass runs first.
    source = {
      10 => [{ chain_kind: :save, phase: :before, filter: :child_hook, only: nil, except: nil }],
      20 => [{ chain_kind: :save, phase: :before, filter: :parent_hook, only: nil, except: nil }]
    }
    ctx = build_context([10, 20], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    # parent_hook (ancestor) should run before child_hook
    assert_equal [:parent_hook, :child_hook], ctx.invoked
  end

  it "preserves declaration order for multiple filters on the SAME class" do
    # Regression guard: CommentsController declares before_action :set_post
    # then :set_comment then :authenticate_user!. The old code reversed the
    # entire collected array (not just the ancestor order), so :set_comment
    # ran BEFORE :set_post → NoMethodError: undefined method 'comments' for
    # nil. Filters on the same class MUST run in declaration order.
    source = {
      10 => [
        { chain_kind: :process_action, phase: :before, filter: :set_post, only: nil, except: nil },
        { chain_kind: :process_action, phase: :before, filter: :set_comment, only: nil, except: nil },
        { chain_kind: :process_action, phase: :before, filter: :authenticate_user!, only: nil, except: nil }
      ]
    }
    ctx = build_context([10], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :process_action)
    assert_equal [:set_post, :set_comment, :authenticate_user!], ctx.invoked
  end

  it "runs superclass filters before same-class filters (mixed hierarchy)" do
    # Parent(20) declares :parent_hook; Child(10) declares :child_a then
    # :child_b. Rails order: parent_hook, child_a, child_b.
    # The old reverse_each bug would yield: child_b, child_a, parent_hook.
    source = {
      20 => [{ chain_kind: :save, phase: :before, filter: :parent_hook, only: nil, except: nil }],
      10 => [
        { chain_kind: :save, phase: :before, filter: :child_a, only: nil, except: nil },
        { chain_kind: :save, phase: :before, filter: :child_b, only: nil, except: nil }
      ]
    }
    ctx = build_context([10, 20], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    assert_equal [:parent_hook, :child_a, :child_b], ctx.invoked
  end

  it "does not run filters declared for a different chain kind" do
    source = {
      10 => [{ chain_kind: :save, phase: :before, filter: :save_hook, only: nil, except: nil }],
      20 => [{ chain_kind: :destroy, phase: :before, filter: :destroy_hook, only: nil, except: nil }]
    }
    ctx = build_context([10, 20], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source)
    t.before(ctx, :save)
    assert_includes ctx.invoked, :save_hook
    refute_includes ctx.invoked, :destroy_hook
  end

  # A context whose `send` raises "un-shareable Proc" for certain filters,
  # simulating an ActiveRecord-generated `define_method(&block)` method that
  # cannot be called cross-Ractor. The transport must SKIP the failing filter
  # and CONTINUE the chain so app-defined `def` callbacks still run.
  class UnshareableProcContext < FakeContext
    attr_reader :invoked, :unshareable_filters

    def initialize(klass, unshareable_filters)
      super(klass)
      @unshareable_filters = Set.new(unshareable_filters)
    end

    def send(name, *args, &block)
      if @unshareable_filters.include?(name)
        raise RuntimeError, "defined with an un-shareable Proc in a different Ractor"
      end
      super
    end

    def __send__(name, *args, &block)
      send(name, *args, &block)
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  it "skips unshareable-Proc filters and continues the chain" do
    source = {
      10 => [
        { chain_kind: :save, phase: :before, filter: :autosave_associated_records_for_category, only: nil, except: nil },
        { chain_kind: :save, phase: :before, filter: :normalize_title, only: nil, except: nil }
      ]
    }
    klass = build_klass_chain([10])
    ctx = UnshareableProcContext.new(klass, [:autosave_associated_records_for_category])
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:save])
    t.before(ctx, :save)
    # The unshareable filter was skipped (never recorded as invoked)
    refute_includes ctx.invoked, :autosave_associated_records_for_category
    # The plain-def filter ran after the skipped one
    assert_includes ctx.invoked, :normalize_title
  end

  it "re-raises non-unshareable errors from filter dispatch" do
    source = {
      10 => [{ chain_kind: :save, phase: :before, filter: :boom, only: nil, except: nil }]
    }
    klass = build_klass_chain([10])

    ctx = Class.new(FakeContext) do
      def send(name, *args, &block)
        raise NoMethodError, "totally different error"
      end
      alias __send__ send
    end.new(klass)

    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:save])
    assert_raises(NoMethodError) { t.before(ctx, :save) }
  end

  # Halt semantics (Rails-accurate): a before filter that returns exactly
  # `false` halts the chain (model halt semantics), and a context that is
  # `performed?` after a filter halts (the ActionController `:process_action`
  # terminator — how http_basic_authenticate_with's 401 stops the action:
  # it sets response_body directly and returns truthy).
  it "halts the chain when a filter returns exactly false" do
    source = {
      10 => [
        { chain_kind: :save, phase: :before, filter: :false_hook, only: nil, except: nil },
        { chain_kind: :save, phase: :before, filter: :later_hook, only: nil, except: nil }
      ]
    }
    klass = build_klass_chain([10])

    ctx = Class.new(FakeContext) do
      def send(name, *args, &block)
        @invoked << name
        name == :false_hook ? false : :ok
      end
      alias __send__ send
    end.new(klass)

    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:save])
    assert_equal false, t.before(ctx, :save), "before must return false as the halt signal"
    assert_equal [:false_hook], ctx.invoked, "filters after the false-returning filter must be skipped"
  end

  it "halts the chain when the context is performed? after a filter" do
    source = {
      10 => [
        { chain_kind: :process_action, phase: :before, filter: :render_hook, only: nil, except: nil },
        { chain_kind: :process_action, phase: :before, filter: :later_hook, only: nil, except: nil }
      ]
    }
    klass = build_klass_chain([10])

    ctx = Class.new(FakeContext) do
      def send(name, *args, &block)
        @invoked << name
        @performed = true if name == :render_hook # simulates render in the filter
        :ok
      end
      alias __send__ send

      def performed?
        @performed == true
      end
    end.new(klass)

    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:process_action])
    assert_equal false, t.before(ctx, :process_action), "performed? must halt with a false signal"
    assert_equal [:render_hook], ctx.invoked, "filters after the performed? filter must be skipped"
  end

  it "does not halt when a filter returns a truthy non-false value" do
    source = {
      10 => [
        { chain_kind: :save, phase: :before, filter: :hook_one, only: nil, except: nil },
        { chain_kind: :save, phase: :before, filter: :hook_two, only: nil, except: nil }
      ]
    }
    klass = build_klass_chain([10])
    ctx = FakeContext.new(klass) # method_missing returns :sent (truthy)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:save])
    refute t.before(ctx, :save)
    assert_equal [:hook_one, :hook_two], ctx.invoked
  end

  # --- validator-object entries (row 1: worker-side validate chain) ---

  # A top-level validator stand-in the transport can const_get: stores its
  # options and records the validated context on the record.
  ::RrsSpecEachValidator = Class.new do
    attr_reader :options

    def initialize(options = {})
      @options = options
    end

    def validate(record)
      (record.validated_by ||= []) << self.class.name
    end
  end

  it "replays validator-object entries by rebuilding the validator and calling validate" do
    source = {
      10 => [{
        chain_kind: :validate, phase: :before,
        filter: "RrsSpecEachValidator",
        validator_attributes: [:body], validator_options: {}.freeze,
        only: nil, except: nil
      }]
    }
    klass = build_klass_chain([10])
    ctx = build_context([10], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])
    refute t.before(ctx, :validate), "a validator entry must never halt the chain"
    assert_equal ["RrsSpecEachValidator"], ctx.validated_by
    # :before entries do not run in the after phase.
    t.after(ctx, :validate)
    assert_equal 1, ctx.validated_by.size
  end

  it "merges validator_attributes back into the reconstructed validator's options" do
    source = {
      10 => [{
        chain_kind: :validate, phase: :before,
        filter: "RrsSpecEachValidator",
        validator_attributes: [:title, :body], validator_options: { minimum: 10 }.freeze,
        only: nil, except: nil
      }]
    }
    ctx = build_context([10], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])
    t.before(ctx, :validate)
    assert_equal ["RrsSpecEachValidator"], ctx.validated_by
  end

  it "ignores the validator's return value (signals via errors, not halt)" do
    falsy_validator = Class.new do
      def initialize(options = {}); end

      def validate(record)
        false # must NOT halt the chain
      end
    end
    Object.const_set(:RrsSpecFalsyValidator, falsy_validator)
    source = {
      10 => [{
        chain_kind: :validate, phase: :before,
        filter: "RrsSpecFalsyValidator",
        validator_attributes: nil, validator_options: nil,
        only: nil, except: nil
      }]
    }
    ctx = build_context([10], source)
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])
    refute t.before(ctx, :validate), "a false .validate return must not halt"
  ensure
    Object.send(:remove_const, :RrsSpecFalsyValidator)
  end

  it "gates validator entries by validation_context (:on)" do
    source = {
      10 => [{
        chain_kind: :validate, phase: :before,
        filter: "RrsSpecEachValidator",
        validator_attributes: [:body], validator_options: {}.freeze,
        only: nil, except: nil, on: [:create].freeze, except_on: nil
      }]
    }
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])

    create_ctx = build_context([10], source)
    def create_ctx.validation_context; :create; end
    t.before(create_ctx, :validate)
    assert_equal ["RrsSpecEachValidator"], create_ctx.validated_by

    update_ctx = build_context([10], source)
    def update_ctx.validation_context; :update; end
    t.before(update_ctx, :validate)
    assert_nil update_ctx.validated_by
  end

  it "gates validator entries by validation_context (:except_on)" do
    source = {
      10 => [{
        chain_kind: :validate, phase: :before,
        filter: "RrsSpecEachValidator",
        validator_attributes: [:body], validator_options: {}.freeze,
        only: nil, except: nil, on: nil, except_on: [:destroy].freeze
      }]
    }
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])

    destroy_ctx = build_context([10], source)
    def destroy_ctx.validation_context; :destroy; end
    t.before(destroy_ctx, :validate)
    assert_nil destroy_ctx.validated_by

    create_ctx = build_context([10], source)
    def create_ctx.validation_context; :create; end
    t.before(create_ctx, :validate)
    assert_equal ["RrsSpecEachValidator"], create_ctx.validated_by
  end

  it "runs on:-gated symbolic entries only in the matching validation context" do
    source = {
      10 => [{ chain_kind: :validate, phase: :before, filter: :custom_check, only: nil, except: nil, on: [:create].freeze, except_on: nil }]
    }
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: source, kinds: [:validate])

    create_ctx = build_context([10], source)
    def create_ctx.validation_context; :create; end
    t.before(create_ctx, :validate)
    assert_includes create_ctx.invoked, :custom_check

    update_ctx = build_context([10], source)
    def update_ctx.validation_context; :update; end
    t.before(update_ctx, :validate)
    refute_includes update_ctx.invoked, :custom_check
  end
end