# frozen_string_literal: true

# Specs for the ActiveJob::Serializers freezer patch — the registry Set +
# index Hash are class ivars on ActiveJob::Serializers; workers reading them
# during custom-argument serialization need those values shareable. The
# patch registers the class with Freezers::GlobalClassIvarFreezer, whose
# prepare-time pass freezes the ivar values in place (upstream bodies keep
# working verbatim from workers).
#
# Run: bundle exec ruby -Ilib -Ispec spec/active_job_serializers_patch_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/foundation/role_defaults"
require_relative "../lib/ractor_rails_shim/patches/active_job"
require_relative "../lib/ractor_rails_shim/roles/freezers"

class ActiveJobSerializersPatchSpec < Minitest::Spec
  # A stand-in for ::ActiveJob::Serializers so register_target! exercises
  # its real defined?-true path without loading activejob (not in this
  # bundle). Created fresh per test; the freezer target list is restored
  # in teardown.
  def with_fake_serializers_module
    fake = Module.new
    ::Object.const_set(:ActiveJob, Module.new) unless defined?(::ActiveJob)
    ::ActiveJob.const_set(:Serializers, fake) unless defined?(::ActiveJob::Serializers)
    yield
  ensure
    ::ActiveJob.__send__(:remove_const, :Serializers) if ::ActiveJob.const_defined?(:Serializers, false)
    ::Object.__send__(:remove_const, :ActiveJob) if ::ActiveJob.const_defined?(:ActiveJob, false)
  end

  def teardown
    RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS.reject! { |t| t == "ActiveJob::Serializers" }
  end

  def test_registers_the_freezer_target_when_active_job_is_loaded
    with_fake_serializers_module do
      assert_equal true, RactorRailsShim::ActiveJobSerializersPatch.register_target!
      assert_includes RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS,
        "ActiveJob::Serializers"
    end
  end

  def test_registration_is_idempotent
    with_fake_serializers_module do
      RactorRailsShim::ActiveJobSerializersPatch.register_target!
      RactorRailsShim::ActiveJobSerializersPatch.register_target!
      assert_equal 1,
        RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS.count { |t| t == "ActiveJob::Serializers" }
    end
  end

  def test_apply_without_active_job_defers_and_does_not_raise
    result = RactorRailsShim::ActiveJobSerializersPatch.register_target!
    refute_equal true, result # no ActiveJob in this bundle → deferred
    refute_includes RactorRailsShim::Freezers::GlobalClassIvarFreezer::TARGETS,
      "ActiveJob::Serializers"
  end

  def test_frozen_serializers_registry_is_worker_readable
    # Simulate the freezer outcome: a shareable Set of stateless serializer
    # stand-ins + a frozen index Hash on a class's singleton. A worker must
    # be able to READ both (the upstream bodies only read these ivars).
    serializer_class = Class.new do
      def serialize?(arg) = arg.is_a?(Struct.new(:v))
    end
    Ractor.make_shareable(serializer_class)
    index = {serializer_class => "inst"}
    set = Set.new([:sym_serializer])
    Ractor.make_shareable(index)
    Ractor.make_shareable(set)

    holder = Class.new do
      @index = index
      @set = set
      class << self
        attr_reader :index, :set
      end
    end
    Ractor.make_shareable(holder)

    result = Ractor.new(holder, serializer_class) do |h, klass|
      [h.index[klass], h.set.include?(:sym_serializer)]
    end.value
    assert_equal ["inst", true], result
  end
end
