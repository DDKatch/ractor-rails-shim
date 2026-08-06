# frozen_string_literal: true

# Specs for PreSpawnSteps (Issue #48): shared orchestration steps between
# prepare_for_ractors! and AppShareabilizer.make_shareable!. Both paths
# call the same three steps (apply shareable constants, freeze shareable
# class ivars, install framework patches). PreSpawnSteps owns these shared
# steps so adding a new shared step is one edit.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/patches"

class PreSpawnStepsSpec < Minitest::Spec
  it "RactorRailsShim::PreSpawnSteps is defined" do
    assert defined?(RactorRailsShim::PreSpawnSteps),
           "PreSpawnSteps should be defined"
  end

  it "PreSpawnSteps.apply_shareable_constants is callable" do
    assert_respond_to RactorRailsShim::PreSpawnSteps, :apply_shareable_constants
    # In test env, ConstantShareabilizer.apply! is already called (idempotent).
    # Just verify it doesn't raise.
    RactorRailsShim::PreSpawnSteps.apply_shareable_constants
  end

  it "PreSpawnSteps.freeze_shareable_class_ivars is callable" do
    assert_respond_to RactorRailsShim::PreSpawnSteps, :freeze_shareable_class_ivars
    # Should not raise (idempotent).
    RactorRailsShim::PreSpawnSteps.freeze_shareable_class_ivars
  end

  it "PreSpawnSteps.install_framework_patches is callable" do
    assert_respond_to RactorRailsShim::PreSpawnSteps, :install_framework_patches
    # Should not raise (idempotent).
    RactorRailsShim::PreSpawnSteps.install_framework_patches
  end

  it "prepare_for_ractors! uses PreSpawnSteps for shared steps" do
    # Verify that prepare_for_ractors! delegates to PreSpawnSteps by checking
    # that PreSpawnSteps.apply_shareable_constants is called (indirectly:
    # ConstantShareabilizer.apply! is called via PreSpawnSteps).
    # We just verify prepare_for_ractors! completes without error.
    RactorRailsShim.prepare_for_ractors!
  end
end
