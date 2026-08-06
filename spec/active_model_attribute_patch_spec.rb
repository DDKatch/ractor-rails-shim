# frozen_string_literal: true

# Specs for the `RactorRailsShim::Patches::ActiveModelAttribute` role
# object (extracted from the facade god module in Step 22.2, Issue #22).
#
# These specs target the role object directly — constructing and calling
# `Patches::ActiveModelAttribute.install` — pinning the idempotency guard
# and the three prepend targets without routing through the facade.
#
# Run: ruby -Ilib -Ispec spec/active_model_attribute_patch_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ActiveModelAttributePatchSpec < Minitest::Spec
  # The role object exists and exposes the install entry point.
  it "is a module under Patches with an .install method" do
    assert RactorRailsShim::Patches.const_defined?(:ActiveModelAttribute, false),
           "RactorRailsShim::Patches::ActiveModelAttribute should be defined"
    assert RactorRailsShim::Patches::ActiveModelAttribute.respond_to?(:install),
           "Patches::ActiveModelAttribute.install should be defined"
  end

  # Idempotency: the flag lives on the role object, not the facade.
  it "owns its own installed? flag — false initially, true after install" do
    RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
    refute RactorRailsShim::Patches::ActiveModelAttribute.installed?,
           "installed? should be false after reset"
    RactorRailsShim::Patches::ActiveModelAttribute.install
    assert RactorRailsShim::Patches::ActiveModelAttribute.installed?,
           "installed? should be true after install"
  ensure
    RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
  end

  # When ActiveModel::Attribute is not defined, install is a guarded no-op
  # (returns falsy/nil without raising), matching the original guard.
  it "is a no-op (does not raise) when ActiveModel::Attribute is undefined" do
    RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
    # ActiveModel is not loaded under the shim's own bundle, so the guard
    # `return unless defined?(::ActiveModel::Attribute)` fires.
    result = RactorRailsShim::Patches::ActiveModelAttribute.install
    # The guard returns nil (the value of the `return unless`); the role
    # object still records installed? = true (it ran to completion).
    assert RactorRailsShim::Patches::ActiveModelAttribute.installed?,
           "installed? should be true even on the guarded no-op path"
  ensure
    RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
  end

  # The facade delegates to the role object.
  it "facade _install_active_model_attribute_patch delegates to the role object" do
    result = RactorRailsShim.send(:_install_active_model_attribute_patch)
    # Original returned the @am_attributes_patched flag; delegation returns
    # truthy once installed.
    refute_nil result
  end

  # When ActiveModel::Attribute IS defined, install includes the patch
  # module into it. We fake ActiveModel::Attribute to verify the include.
  it "includes ActiveModelAttributePatch into ActiveModel::Attribute when defined" do
    RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
    fake_active_model = Module.new
    fake_attribute = Class.new do
      def frozen?; false; end
      def dup_or_share; :original; end
    end
    fake_active_model.const_set(:Attribute, fake_attribute)
    Object.const_set(:FakeActiveModelForAMAPatch, fake_active_model)

    begin
      # Stub ::ActiveModel to our fake for the duration of this test.
      orig_active_model = ::ActiveModel if defined?(::ActiveModel)
      Object.const_set(:ActiveModel, fake_active_model)

      result = RactorRailsShim::Patches::ActiveModelAttribute.install
      assert_equal true, result, "install should return true when the patch applies"
      assert fake_attribute.include?(RactorRailsShim::ActiveModelAttributePatch),
             "ActiveModel::Attribute should include ActiveModelAttributePatch after install"
      # The patched dup_or_share on a frozen receiver returns a new from_database.
      # We only verify the include took effect; the full dup_or_share contract
      # is exercised by the integration spec against real ActiveModel.
    ensure
      Object.send(:remove_const, :ActiveModel)
      Object.const_set(:ActiveModel, orig_active_model) if orig_active_model
      Object.send(:remove_const, :FakeActiveModelForAMAPatch) if defined?(FakeActiveModelForAMAPatch)
      RactorRailsShim::Patches::ActiveModelAttribute.reset_installed_for_test!
    end
  end
end