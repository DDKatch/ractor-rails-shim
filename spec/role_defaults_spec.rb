# frozen_string_literal: true

# Specs for RoleDefaults mixin (Issue #44, POODR §8e DRY).
# Asserts the three default methods resolve to the canonical facade
# lookups — the single source of truth for every role's configure
# seam default.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class RoleDefaultsSpec < Minitest::Spec
  # RoleDefaults exists as a module
  it "is a module" do
    assert RactorRailsShim.const_defined?(:RoleDefaults, false),
           "RactorRailsShim::RoleDefaults should be defined"
    assert_kind_of Module, RactorRailsShim::RoleDefaults
  end

  # Extend a dummy module with RoleDefaults and verify the three defaults
  it "default_funnel resolves to RactorRailsShim::Funnel.method(:swallow)" do
    dummy = Module.new
    dummy.extend RactorRailsShim::RoleDefaults
    assert_equal RactorRailsShim::Funnel.method(:swallow),
                 dummy.default_funnel
  end

  it "default_safe_const_get resolves to ConstantShareabilizer.method(:safe_const_get)" do
    dummy = Module.new
    dummy.extend RactorRailsShim::RoleDefaults
    assert_equal RactorRailsShim::ConstantShareabilizer.method(:safe_const_get),
                 dummy.default_safe_const_get
  end

  it "default_reassign_shareable_const resolves to RactorRailsShim.method(:_reassign_shareable_const)" do
    dummy = Module.new
    dummy.extend RactorRailsShim::RoleDefaults
    assert_equal RactorRailsShim.method(:_reassign_shareable_const),
                 dummy.default_reassign_shareable_const
  end

  # Verify extend + override pattern works as documented
  it "a role module can extend RoleDefaults and override a default" do
    custom_funnel = ->(label, &blk) { blk&.call }
    dummy = Module.new do
      extend RactorRailsShim::RoleDefaults
      @funnel = nil

      def self.configure(funnel: nil)
        @funnel = funnel
      end

      def self.reset_configuration
        @funnel = nil
      end

      def self.funnel
        @funnel || default_funnel
      end
    end

    # Before configure: funnel is the RoleDefaults default
    assert_equal RactorRailsShim::Funnel.method(:swallow), dummy.funnel

    # After configure: funnel is the injected callable
    dummy.configure(funnel: custom_funnel)
    assert_equal custom_funnel, dummy.funnel

    # After reset: back to RoleDefaults default
    dummy.reset_configuration
    assert_equal RactorRailsShim::Funnel.method(:swallow), dummy.funnel
  end
end
