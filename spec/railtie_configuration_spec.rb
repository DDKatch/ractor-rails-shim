# frozen_string_literal: true

require "minitest/autorun"

# Specs for the Rails::Railtie::Configuration patch (core.rb
# `_install_railtie_configuration_patch`).
#
# Upstream stores the method_missing-backed option hash in the CLASS
# VARIABLE @@options, which Ruby 4.0 forbids in non-main Ractors
# (Ractor::IsolationError). The patch routes the store through a
# Ractor-aware accessor: upstream @@options on main (semantics unchanged,
# including the incidental cross-instance sharing), a per-instance
# worker-local Hash in workers.
#
# The shim bundle intentionally does NOT depend on railties (the runtime
# gem dependency is activesupport-only), so these specs self-skip unless
# railties happens to be loadable; the worker-side branch is exercised by
# the kino (config_probe, row 138).
begin
  require "rails/railtie/configuration"
rescue LoadError
  nil
end

if defined?(::Rails::Railtie::Configuration)
  class RailtieConfigurationSpec < Minitest::Spec
    # A scratch subclass; the upstream main-side store is SHARED across all
    # Railtie::Configuration instances, so specs use unique option names to
    # avoid cross-contamination with real Rails boot state.
    let(:config) { Class.new(::Rails::Railtie::Configuration).new }

    before { RactorRailsShim::Patches::RailtieConfiguration.install }

    it "writes and reads method_missing-backed options main-side" do
      config.rrs_spec_option = "v1"
      assert_equal "v1", config.rrs_spec_option
    end

    it "reports method_missing-backed options via respond_to?" do
      config.rrs_spec_option = "v1"
      assert_respond_to config, :rrs_spec_option
      refute_respond_to config, :rrs_spec_option_absent
    end

    it "rejects assignment to an actual method" do
      error = assert_raises(NoMethodError) do
        config.eager_load_namespaces = []
      end
      assert_match(/Cannot assign/, error.message)
    end

    it "falls through to super for unknown reads" do
      error = assert_raises(NoMethodError) do
        config.rrs_spec_totally_unknown
      end
      assert_match(/rrs_spec_totally_unknown/, error.message)
    end
  end
end
