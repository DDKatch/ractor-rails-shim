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

  it "defaults to owning only :process_action (model lifecycle kinds are a follow-up)" do
    t = RactorRailsShim::Callbacks::SymbolicTransport.new(source: {})
    assert t.applies_to?(:process_action)
    refute t.applies_to?(:save)
    refute t.applies_to?(:destroy)
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
end