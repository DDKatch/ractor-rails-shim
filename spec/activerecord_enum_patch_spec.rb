# frozen_string_literal: true

# Unit specs for the ActiveRecord enum patches (RAILS_FEATURES row 65).
#
# These run WITHOUT ActiveRecord loaded (the shim bundle has no Rails), so
# they cover the no-AR early paths and the shareable EnumTypeDecorator
# callable. The full worker behavior (predicates/bangs/scopes/values reader
# + EnumType registration replay) is covered by worker_ar_enum_spec.rb (test
# app bundle) and the test app's kino enum probe.
#
# Run: bundle exec rake spec

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class ActiverecordEnumPatchSpec < Minitest::Spec
  it "defines the redefinition entrypoint _redefine_ar_enum_methods!" do
    assert RactorRailsShim.respond_to?(:_redefine_ar_enum_methods!, true),
           "_redefine_ar_enum_methods! must be defined"
  end

  it "defines the pending-mods sharing entrypoint _share_ar_pending_attribute_modifications!" do
    assert RactorRailsShim.respond_to?(:_share_ar_pending_attribute_modifications!, true),
           "_share_ar_pending_attribute_modifications! must be defined"
  end

  it "no-ops cleanly when ActiveRecord is not loaded" do
    # The early-install path runs before Rails boots; without
    # ActiveRecord::Base the entrypoints must return without error.
    assert_nil RactorRailsShim._redefine_ar_enum_methods!
    assert_nil RactorRailsShim._share_ar_pending_attribute_modifications!
  end

  it "EnumTypeDecorator is constructible from shareable inputs and freezes cleanly" do
    decorator = RactorRailsShim.singleton_class.const_get(:EnumTypeDecorator)
                                   .new("state", { "draft" => 0, "moderated" => 1 }, true)
    assert_equal "state", decorator.instance_variable_get(:@enum_name)
    # All inputs are shareable (String / frozen labels hash / bool), so the
    # instance itself must freeze+share — workers construct EnumTypes from
    # it during apply_pending_attribute_modifications.
    Ractor.make_shareable(decorator)
    assert Ractor.shareable?(decorator), "EnumTypeDecorator must be shareable"
  end
end
