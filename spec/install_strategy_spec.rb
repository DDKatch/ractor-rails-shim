# frozen_string_literal: true

# Specs for Issue #26: extract InstallStrategy composition from
# Installer.install (POODR §5 Composition). Removes the last
# `thread_mode?` branch and resolves the StorageStrategy-vs-Installer
# inconsistency.
#
# Run: bundle exec ruby -Ilib -Ispec spec/install_strategy_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class InstallStrategySpec < Minitest::Spec
  RactorRailsShim::RunMode.resolve!

  # --- namespace ---

  it "RactorRailsShim::InstallStrategy is a Module" do
    assert_kind_of Module, RactorRailsShim::InstallStrategy
  end

  it "InstallStrategy::Ractor is a Module" do
    assert_kind_of Module, RactorRailsShim::InstallStrategy::Ractor
  end

  it "InstallStrategy::Thread is a Module" do
    assert_kind_of Module, RactorRailsShim::InstallStrategy::Thread
  end

  # --- strategy selection ---

  it "Installer.install selects Ractor strategy when not in thread mode" do
    RactorRailsShim::RunMode.reset
    RactorRailsShim::RunMode.thread = false
    called = false
    original = RactorRailsShim::InstallStrategy::Ractor.method(:install)
    RactorRailsShim::InstallStrategy::Ractor.define_singleton_method(:install) { called = true }
    RactorRailsShim::Installer.install
    assert called, "Ractor strategy should have been called"
  ensure
    RactorRailsShim::InstallStrategy::Ractor.define_singleton_method(:install, original)
    RactorRailsShim::RunMode.reset
  end

  it "Installer.install selects Thread strategy when in thread mode" do
    RactorRailsShim::RunMode.reset
    RactorRailsShim::RunMode.thread = true
    called = false
    original = RactorRailsShim::InstallStrategy::Thread.method(:install)
    RactorRailsShim::InstallStrategy::Thread.define_singleton_method(:install) { called = true }
    RactorRailsShim::Installer.install
    assert called, "Thread strategy should have been called"
  ensure
    RactorRailsShim::InstallStrategy::Thread.define_singleton_method(:install, original)
    RactorRailsShim::RunMode.reset
  end

  # --- Ractor strategy calls the right methods ---

  it "InstallStrategy::Ractor.install calls the full patch set" do
    called = []
    originals = {}
    %i[install_mattr_accessor install_class_attribute install_zeitwerk_registry
       install_rubygems install_rails_module install_execution_wrapper].each do |m|
      originals[m] = RactorRailsShim.method(m)
      RactorRailsShim.define_singleton_method(m) { called << m }
    end
    originals[:install_shareable_constants] =
      RactorRailsShim::ConstantShareabilizer.method(:install)
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:install) { called << :install_shareable_constants }
    originals[:_install_callback_declaration_capture!] =
      RactorRailsShim::CallbackCapture.method(:install_callback_declaration_capture!)
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!) { called << :_install_callback_declaration_capture! }

    RactorRailsShim::InstallStrategy::Ractor.install

    originals.each_key do |m|
      assert_includes called, m, "Ractor strategy should call #{m}"
    end
  ensure
    RactorRailsShim::ConstantShareabilizer.define_singleton_method(:install, originals[:install_shareable_constants]) if originals[:install_shareable_constants]
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!, originals[:_install_callback_declaration_capture!]) if originals[:_install_callback_declaration_capture!]
    originals.each do |m, orig|
      next if m == :install_shareable_constants || m == :_install_callback_declaration_capture!
      RactorRailsShim.define_singleton_method(m, orig)
    end
  end

  # --- Thread strategy calls the right methods ---

  it "InstallStrategy::Thread.install calls the minimal patch set" do
    called = []
    originals = {}
    %i[install_class_attribute install_execution_wrapper].each do |m|
      originals[m] = RactorRailsShim.method(m)
      RactorRailsShim.define_singleton_method(m) { called << m }
    end
    originals[:_install_callback_declaration_capture!] =
      RactorRailsShim::CallbackCapture.method(:install_callback_declaration_capture!)
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!) { called << :_install_callback_declaration_capture! }

    RactorRailsShim::InstallStrategy::Thread.install

    originals.each_key do |m|
      assert_includes called, m, "Thread strategy should call #{m}"
    end
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!, originals[:_install_callback_declaration_capture!]) if originals[:_install_callback_declaration_capture!]
    originals.each do |m, orig|
      next if m == :_install_callback_declaration_capture!
      RactorRailsShim.define_singleton_method(m, orig)
    end
  end
end
