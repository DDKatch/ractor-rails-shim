# frozen_string_literal: true

# Specs for the SolidQueue worker-enqueue patch (row 110): the prewarm of
# SolidQueue::Batch.migrated? (a lazily-memoized boolean class ivar on a
# frozen engine-model class) and the shareable SerializedTypeDecorator that
# replays the `serialize :arguments, coder: JSON` type decoration that the
# upstream block-callback closure loses in workers.
#
# Run: bundle exec ruby -Ilib -Ispec spec/solid_queue_patch_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/foundation/role_defaults"
require_relative "../lib/ractor_rails_shim/patches/callables"
require_relative "../lib/ractor_rails_shim/patches/solid_queue"

class SolidQueuePatchSpec < Minitest::Spec
  def teardown
    RactorRailsShim::Patches::SolidQueuePatch.instance_variable_set(:@applied, nil)
  end

  def test_apply_without_solid_queue_does_not_raise
    # No SolidQueue in this bundle — apply! must still be idempotent + safe.
    RactorRailsShim::Patches::SolidQueuePatch.apply!
    assert_equal true, RactorRailsShim::Patches::SolidQueuePatch.apply!,
      "apply! must be idempotent"
  end

  def test_prewarm_methods_target_only_the_enqueue_path
    assert_equal ["SolidQueue::Batch", :migrated?],
      RactorRailsShim::Patches::SolidQueuePatch::PREWARM_METHODS.first
  end

  def test_redeclare_symbolic_assumption_guards_non_class
    refute RactorRailsShim::Patches::SolidQueuePatch.redeclare_symbolic_assumption!(Object.new)
    refute RactorRailsShim::Patches::SolidQueuePatch.redeclare_symbolic_assumption!(nil)
  end

  def test_serialized_type_decorator_is_reachable_and_shareable
    coder = Object.new
    Ractor.make_shareable(coder)
    decorator = RactorRailsShim.singleton_class.const_get(:SerializedTypeDecorator)
      .new(coder, false)
    Ractor.make_shareable(decorator)
    assert decorator.is_a?(RactorRailsShim.singleton_class.const_get(:SerializedTypeDecorator)),
      "the decorator must be reachable via the singleton-class const (same access path as EnumTypeDecorator)"
    assert Ractor.shareable?(decorator), "the decorator must freeze+share cleanly"
  end
end
