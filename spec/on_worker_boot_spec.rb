# frozen_string_literal: true

# Specs for the on_worker_boot hook (per-worker re-arm blocks) and the
# string-source WorkerBootEval entry. Pure-Ruby, no Rails dependency.
#
# Run: bundle exec ruby -Ilib -Ispec spec/on_worker_boot_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class OnWorkerBootTest < Minitest::Test
  def setup
    RactorRailsShim::Registry.send(:instance_variable_set, :@worker_boot_blocks, [])
  end

  def teardown
    RactorRailsShim::Registry.send(:instance_variable_set, :@worker_boot_blocks, [])
  end

  def test_string_source_is_evaluated_ractor_locally_on_call
    RactorRailsShim.on_worker_boot("@__shim_spec_marker = :set")
    entry = RactorRailsShim::Registry.worker_boot_blocks.first
    assert_instance_of RactorRailsShim::WorkerBootEval, entry
    entry.call
    assert_equal :set, Object.instance_variable_get(:@__shim_spec_marker)
  ensure
    Object.instance_variable_set(:@__shim_spec_marker, nil)
  end

  def test_unshareable_block_raises_with_guidance
    block = -> { RactorRailsShim.storage[:marker] }
    assert_raises(ArgumentError) { RactorRailsShim.on_worker_boot(&block) }
  end

  def test_string_and_block_rejected_together
    assert_raises(ArgumentError) do
      RactorRailsShim.on_worker_boot("nil") { nil }
    end
  end

  def test_empty_registration_raises
    assert_raises(ArgumentError) { RactorRailsShim.on_worker_boot }
  end

  def test_worker_boot_eval_source_is_frozen
    entry = RactorRailsShim.on_worker_boot("nil")
    assert entry.instance_variable_get(:@source).frozen?
  end

  def test_unshareable_block_error_message_suggests_string_form
    block = -> {}
    error = assert_raises(ArgumentError) { RactorRailsShim.on_worker_boot(&block) }
    assert_match(/source STRING/, error.message)
  end
end

# A shareable self context for the block form: blocks defined inside a class
# body have the class as self — shareable.
class OnWorkerBootShareableBlockHost
  HOSTED_BLOCK = lambda do
    RactorRailsShim.storage[:__shim_hosted_marker] = :ran
  end
end

class OnWorkerBootShareableBlockTest < Minitest::Test
  def setup
    RactorRailsShim::Registry.send(:instance_variable_set, :@worker_boot_blocks, [])
  end

  def teardown
    RactorRailsShim::Registry.send(:instance_variable_set, :@worker_boot_blocks, [])
    RactorRailsShim.storage.delete(:__shim_hosted_marker)
  end

  def test_block_with_shareable_self_is_accepted_and_callable
    RactorRailsShim.on_worker_boot(&OnWorkerBootShareableBlockHost::HOSTED_BLOCK)
    entry = RactorRailsShim::Registry.worker_boot_blocks.first
    assert Ractor.shareable?(entry)
    entry.call
    assert_equal :ran, RactorRailsShim.storage[:__shim_hosted_marker]
  end
end
