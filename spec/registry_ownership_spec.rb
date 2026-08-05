# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the Issue #35 contract: Registry OWNS the nine registries as
# instance variables. The facade constants are aliases that share the
# same object (mutable registries) or track the reassignment (frozen
# registries, via _reassign_shareable_const which updates both paths).
class RegistryOwnershipSpec < Minitest::Spec
  Registry = RactorRailsShim::Registry

  # --- Registry owns storage (the facade constants are aliases) ---

  it "class_attributes storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.class_attributes, RactorRailsShim::CLASS_ATTRIBUTES
  end

  it "mattr_defaults storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.mattr_defaults, RactorRailsShim::MATTR_DEFAULTS
  end

  it "class_attr_values storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.class_attr_values, RactorRailsShim::CLASS_ATTR_VALUES
  end

  it "shareable_mattr_defaults storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.shareable_mattr_defaults, RactorRailsShim::SHAREABLE_MATTR_DEFAULTS
  end

  it "shareable_constants storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.shareable_constants, RactorRailsShim::SHAREABLE_CONSTANTS
  end

  it "shareable_class_ivars storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.shareable_class_ivars, RactorRailsShim::SHAREABLE_CLASS_IVARS
  end

  it "abstract_registry storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.abstract_registry, RactorRailsShim::ABSTRACT_REGISTRY
  end

  it "view_context_registry storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.view_context_registry, RactorRailsShim::VIEW_CONTEXT_REGISTRY
  end

  it "shareable_fallback storage lives on Registry, aliased by the facade constant" do
    assert_same Registry.shareable_fallback, RactorRailsShim::SHAREABLE_FALLBACK
  end

  # --- frozen (shareable) registries reassign through _reassign_shareable_const
  # (which updates BOTH the facade constant and the Registry instance variable) ---

  it "reassigning SHAREABLE_FALLBACK updates the facade constant AND Registry" do
    old = RactorRailsShim::SHAREABLE_FALLBACK
    new_val = Ractor.make_shareable({ rrs_ownership_test: :yes }.freeze)
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, new_val)
    assert_same new_val, RactorRailsShim::SHAREABLE_FALLBACK
    assert_same new_val, Registry.shareable_fallback
    assert_equal :yes, RactorRailsShim::SHAREABLE_FALLBACK[:rrs_ownership_test]
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, old) if old
  end

  it "reassigning SHAREABLE_MATTR_DEFAULTS updates the facade constant AND Registry" do
    old = RactorRailsShim::SHAREABLE_MATTR_DEFAULTS
    new_val = Ractor.make_shareable({ rrs_omd_test: :yes }.freeze)
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, new_val)
    assert_same new_val, RactorRailsShim::SHAREABLE_MATTR_DEFAULTS
    assert_same new_val, Registry.shareable_mattr_defaults
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_MATTR_DEFAULTS, old) if old
  end

  it "reassigning ABSTRACT_REGISTRY updates the facade constant AND Registry" do
    old = RactorRailsShim::ABSTRACT_REGISTRY
    new_val = Ractor.make_shareable({ Object => true }.freeze)
    RactorRailsShim._reassign_shareable_const(:ABSTRACT_REGISTRY, new_val)
    assert_same new_val, RactorRailsShim::ABSTRACT_REGISTRY
    assert_same new_val, Registry.abstract_registry
  ensure
    RactorRailsShim._reassign_shareable_const(:ABSTRACT_REGISTRY, old) if old
  end

  it "reassigning VIEW_CONTEXT_REGISTRY updates the facade constant AND Registry" do
    old = RactorRailsShim::VIEW_CONTEXT_REGISTRY
    new_val = Ractor.make_shareable({ Object => Class.new }.freeze)
    RactorRailsShim._reassign_shareable_const(:VIEW_CONTEXT_REGISTRY, new_val)
    assert_same new_val, RactorRailsShim::VIEW_CONTEXT_REGISTRY
    assert_same new_val, Registry.view_context_registry
  ensure
    RactorRailsShim._reassign_shareable_const(:VIEW_CONTEXT_REGISTRY, old) if old
  end

  # --- mutability contracts (unchanged from prior registry_spec) ---

  it "class_attributes is appendable" do
    size_before = Registry.class_attributes.size
    Registry.class_attributes << ["TestOwner", :test_attr, :test_key, nil]
    assert_equal size_before + 1, Registry.class_attributes.size
  ensure
    Registry.class_attributes.pop
  end

  it "shareable_constants is appendable" do
    size_before = Registry.shareable_constants.size
    Registry.shareable_constants << "TestModule::CONSTANT"
    assert_equal size_before + 1, Registry.shareable_constants.size
  ensure
    Registry.shareable_constants.pop
  end

  it "mattr_defaults is writable" do
    key = :__ractor_rails_shim_test_mattr__
    Registry.mattr_defaults[key] = :test_value
    assert_equal :test_value, Registry.mattr_defaults[key]
  ensure
    Registry.mattr_defaults.delete(key)
  end

  it "class_attr_values is writable" do
    key = :__ractor_rails_shim_test_class_attr__
    Registry.class_attr_values[key] = :test_value
    assert_equal :test_value, Registry.class_attr_values[key]
  ensure
    Registry.class_attr_values.delete(key)
  end
end