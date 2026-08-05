# frozen_string_literal: true

require "minitest/autorun"
require "active_support/class_attribute"
require "active_support/execution_wrapper"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Minimal mattr_accessor stub on Module so super in the prepended patch finds
# it (matches shim_spec.rb / sentinel_spec.rb setup).
unless Module.method_defined?(:mattr_accessor, true)
  Module.module_eval do
    def mattr_accessor(name, default: nil, **)
      cv = "@@#{name}"
      class_variable_set(cv, default) unless class_variable_defined?(cv)
      define_singleton_method(name) { class_variable_get(cv) }
      define_singleton_method("#{name}=") { |v| class_variable_set(cv, v) }
    end
  end
end

RactorRailsShim.send(:install_mattr_accessor)

# Pins the split of mattr_accessor's definition-time side effects into three
# single-responsibility helpers (POODR: "define an accessor" was doing four
# things — super, registry mutation, constant reassignment, method redefine).
# The split makes each step independently callable + specable.
class MattrSplitSpec < Minitest::Spec
  # A throwaway module per test so registry mutations don't leak across specs.
  def fresh_module
    Module.new.tap { |m| Object.const_set(:"MattrSplitTest#{m.object_id.abs}", m) }
  end

  it "_seed_mattr_default stores the default in MATTR_DEFAULTS" do
    mod = fresh_module
    key = :"ractor_rails_shim_mattr_#{mod.name}_flag"
    RactorRailsShim._seed_mattr_default(key, :my_default)
    assert_equal :my_default, RactorRailsShim::MATTR_DEFAULTS[key]
  ensure
    RactorRailsShim::MATTR_DEFAULTS.delete(key) if key
    Object.send(:remove_const, mod.name.to_sym) if mod
  end

  it "_seed_mattr_default rebuilds SHAREABLE_MATTR_DEFAULTS when default is shareable" do
    mod = fresh_module
    key = :"ractor_rails_shim_mattr_#{mod.name}_shareable_flag"
    RactorRailsShim._seed_mattr_default(key, :shareable_value)
    assert_equal :shareable_value, RactorRailsShim::SHAREABLE_MATTR_DEFAULTS[key]
    assert RactorRailsShim::SHAREABLE_MATTR_DEFAULTS.frozen?
    assert Ractor.shareable?(RactorRailsShim::SHAREABLE_MATTR_DEFAULTS)
  ensure
    Object.send(:remove_const, mod.name.to_sym) if mod
  end

  it "_seed_mattr_default does NOT add unshareable defaults to SHAREABLE_MATTR_DEFAULTS" do
    mod = fresh_module
    key = :"ractor_rails_shim_mattr_#{mod.name}_unshareable_flag"
    unshareable = []
    RactorRailsShim._seed_mattr_default(key, unshareable)
    assert_nil RactorRailsShim::SHAREABLE_MATTR_DEFAULTS[key],
               "unshareable default must not enter the shareable subset"
    assert_equal unshareable, RactorRailsShim::MATTR_DEFAULTS[key],
                 "unshareable default still goes into the full registry"
  ensure
    RactorRailsShim::MATTR_DEFAULTS.delete(key) if key
    Object.send(:remove_const, mod.name.to_sym) if mod
  end

  it "_register_for_fallback pushes [mod_name, sym, key, default] to CLASS_ATTRIBUTES" do
    mod_name = "MattrSplitRegisterTest"
    key = :"ractor_rails_shim_mattr_#{mod_name}_flag"
    before = RactorRailsShim::CLASS_ATTRIBUTES.length
    RactorRailsShim._register_for_fallback(mod_name, :flag, key, :default_val)
    after = RactorRailsShim::CLASS_ATTRIBUTES.length
    assert_equal before + 1, after
    entry = RactorRailsShim::CLASS_ATTRIBUTES.last
    assert_equal [mod_name, :flag, key, :default_val], entry
  ensure
    RactorRailsShim::CLASS_ATTRIBUTES.pop if RactorRailsShim::CLASS_ATTRIBUTES.last&.first == mod_name
  end
end