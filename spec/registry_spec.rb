# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class RegistrySpec < Minitest::Spec
  Registry = RactorRailsShim::Registry

  # --- readers exist for all nine registries ---

  it "exposes class_attributes" do
    assert_same RactorRailsShim::CLASS_ATTRIBUTES, Registry.class_attributes
  end

  it "exposes mattr_defaults" do
    assert_same RactorRailsShim::MATTR_DEFAULTS, Registry.mattr_defaults
  end

  it "exposes class_attr_values" do
    assert_same RactorRailsShim::CLASS_ATTR_VALUES, Registry.class_attr_values
  end

  it "exposes shareable_mattr_defaults" do
    assert_same RactorRailsShim::SHAREABLE_MATTR_DEFAULTS, Registry.shareable_mattr_defaults
  end

  it "exposes shareable_constants" do
    assert_same RactorRailsShim::SHAREABLE_CONSTANTS, Registry.shareable_constants
  end

  it "exposes shareable_class_ivars" do
    assert_same RactorRailsShim::SHAREABLE_CLASS_IVARS, Registry.shareable_class_ivars
  end

  it "exposes abstract_registry" do
    assert_same RactorRailsShim::ABSTRACT_REGISTRY, Registry.abstract_registry
  end

  it "exposes view_context_registry" do
    assert_same RactorRailsShim::VIEW_CONTEXT_REGISTRY, Registry.view_context_registry
  end

  it "exposes shareable_fallback" do
    assert_same RactorRailsShim::SHAREABLE_FALLBACK, Registry.shareable_fallback
  end

  # --- mutability contracts ---

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
