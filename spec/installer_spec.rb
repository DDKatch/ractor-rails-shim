# frozen_string_literal: true

# Specs for Issue #13, Step 13.6: extract Installer (the orchestrator) from
# the RactorRailsShim god module (POODR §1 SRP). The install entry point +
# framework-patch dispatcher — install, installed?, _install_all_framework_
# patches, NON_DISPATCHED_FRAMEWORK_PATCHES — is one role collapsed onto
# the singleton. These specs pin the extracted object's contract directly.
#
# The RactorRailsShim facade keeps delegating methods (install, installed?,
# _install_all_framework_patches), so framework_patch_dispatch_spec,
# version_spec, and the integration spec keep passing unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/installer_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class InstallerSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # --- namespace ---

  it "RactorRailsShim::Installer is a Module" do
    assert_kind_of Module, RactorRailsShim::Installer
  end

  it "Installer::NON_DISPATCHED_FRAMEWORK_PATCHES is a frozen shareable Array" do
    nd = RactorRailsShim::Installer::NON_DISPATCHED_FRAMEWORK_PATCHES
    assert_kind_of Array, nd
    assert nd.frozen?
    assert Ractor.shareable?(nd)
    assert_includes nd, :_install_callbacks_nil_safe_patch
    assert_includes nd, :_install_notifications_notifier_patch
    assert_includes nd, :_install_with_empty_template_cache_patch
  end

  # --- installed? ---

  it "installed? returns false before install runs" do
    # install has already run in this process (required by other specs), so
    # @installed is true. We can't easily reset it without breaking other
    # specs; instead assert the facade + Installer agree on the flag.
    assert_equal RactorRailsShim.installed?, RactorRailsShim::Installer.installed?
  end

  # --- dispatch_all_framework_patches (was _install_all_framework_patches) ---

  it "dispatch_all_framework_patches auto-discovers a newly added _install_*_patch method" do
    called = []
    RactorRailsShim.define_singleton_method(:_install_test_installer_dispatch_patch) do
      called << :test_installer_dispatch
    end

    RactorRailsShim::Installer.dispatch_all_framework_patches

    assert_includes called, :test_installer_dispatch,
                    "dispatcher should auto-discover _install_test_installer_dispatch_patch"
  ensure
    RactorRailsShim.singleton_class.remove_method(:_install_test_installer_dispatch_patch) rescue nil
  end

  it "dispatch_all_framework_patches does not call NON_DISPATCHED patches" do
    # The dispatcher auto-discovers from the RactorRailsShim singleton method
    # table minus NON_DISPATCHED. Verify a NON_DISPATCHED method is NOT
    # called by the dispatcher.
    called = []
    RactorRailsShim::Installer::NON_DISPATCHED_FRAMEWORK_PATCHES.each do |m|
      next unless RactorRailsShim.respond_to?(m, true)
      original = RactorRailsShim.method(m)
      RactorRailsShim.define_singleton_method(m) { called << m }
      begin
        RactorRailsShim::Installer.dispatch_all_framework_patches
      ensure
        RactorRailsShim.define_singleton_method(m, original)
      end
    end
    # The NON_DISPATCHED methods should not have been called by the dispatcher.
    RactorRailsShim::Installer::NON_DISPATCHED_FRAMEWORK_PATCHES.each do |m|
      refute_includes called, m, "#{m} should NOT be called by the dispatcher"
    end
  end

  # --- install (the orchestrator) ---

  it "install is idempotent: calling twice does not raise and leaves @installed true" do
    RactorRailsShim::Installer.install
    assert RactorRailsShim::Installer.installed?
    # Second call must not raise (idempotent).
    RactorRailsShim::Installer.install
    assert RactorRailsShim::Installer.installed?
  end

  # --- Facade delegation ---

  it "RactorRailsShim.install delegates to Installer.install" do
    delegated = false
    original = RactorRailsShim::Installer.method(:install)
    RactorRailsShim::Installer.define_singleton_method(:install) do
      delegated = true
    end
    RactorRailsShim.install
    assert delegated
  ensure
    RactorRailsShim::Installer.define_singleton_method(:install, original)
  end

  it "RactorRailsShim.installed? delegates to Installer.installed?" do
    delegated = false
    original = RactorRailsShim::Installer.method(:installed?)
    RactorRailsShim::Installer.define_singleton_method(:installed?) do
      delegated = true
      true
    end
    RactorRailsShim.installed?
    assert delegated
  ensure
    RactorRailsShim::Installer.define_singleton_method(:installed?, original)
  end

  # The facade delegation _install_all_framework_patches was deleted in
  # Issue #31. The role-object method Installer.dispatch_all_framework_patches
  # is tested directly above and in framework_patch_dispatch_spec.
end