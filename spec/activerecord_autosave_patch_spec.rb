# frozen_string_literal: true

# TDD spec for the ActiveRecord autosave association method redefine patch.
#
# ActiveRecord generates `autosave_associated_records_for_<assoc>` methods via
# `define_method(&block)` in `define_non_cyclic_method`. The block captures a
# binding from the main Ractor, so calling the method in a worker raises
# "defined with an un-shareable Proc in a different Ractor".
#
# The patch aliases `add_autosave_association_callbacks` (and
# `define_autosave_validation_callbacks`) to call the original (which registers
# the callback + creates the unshareable method) and then immediately redefines
# the method via string eval (compiled `def`, no captured binding). The
# reflection is stored in a frozen shareable registry keyed by
# `[model_name, method_name]` so a worker can look it up at call time.
#
# Run: bundle exec ruby -Ilib -Ispec spec/activerecord_autosave_patch_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ActiverecordAutosavePatchSpec < Minitest::Spec
  it "installs the patch method _install_activerecord_autosave_patch" do
    assert RactorRailsShim.respond_to?(:_install_activerecord_autosave_patch, true),
           "_install_activerecord_autosave_patch must be defined"
  end

  it "registers the patch" do
    # The patch is idempotent; just verify it runs without error when AR is
    # not yet loaded (early-install path) and when it is.
    RactorRailsShim._install_activerecord_autosave_patch
    assert RactorRailsShim.instance_variable_get(:@ar_autosave_patched),
           "patch should set @ar_autosave_patched"
  end

  it "defines SHAREABLE_AUTOSAVE_REFLECTIONS registry constant" do
    RactorRailsShim._install_activerecord_autosave_patch
    assert RactorRailsShim.const_defined?(:SHAREABLE_AUTOSAVE_REFLECTIONS, false),
           "SHAREABLE_AUTOSAVE_REFLECTIONS must be defined on RactorRailsShim"
    registry = RactorRailsShim::SHAREABLE_AUTOSAVE_REFLECTIONS
    assert Ractor.shareable?(registry),
           "SHAREABLE_AUTOSAVE_REFLECTIONS must be Ractor-shareable"
  end
end