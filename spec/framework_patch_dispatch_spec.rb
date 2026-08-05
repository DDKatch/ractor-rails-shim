# frozen_string_literal: true

# Spec for the Open/Closed refactor of _install_all_framework_patches.
#
# The dispatcher must auto-discover every _install_*_patch singleton method
# instead of hardcoding a literal call list. Adding a new patch method should
# NOT require editing _install_all_framework_patches — the method table IS
# the registry.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class FrameworkPatchDispatchSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # The set of _install_*_patch methods that are intentionally called from
  # OTHER install paths (not from the dispatcher). They must be excluded
  # from auto-discovery.
  NON_DISPATCHED = %i[
    _install_callbacks_nil_safe_patch
    _install_notifications_notifier_patch
    _install_with_empty_template_cache_patch
  ].freeze

  it "auto-discovers a newly added _install_*_patch method" do
    called = []
    RactorRailsShim.define_singleton_method(:_install_test_auto_dispatch_patch) do
      called << :test_auto_dispatch
    end

    RactorRailsShim._install_all_framework_patches

    assert_includes called, :test_auto_dispatch,
                    "dispatcher should auto-discover _install_test_auto_dispatch_patch"
  ensure
    RactorRailsShim.singleton_class.remove_method(:_install_test_auto_dispatch_patch) rescue nil
  end

  # Read the source of _install_all_framework_patches from the file.
  def dispatcher_source
    file, line = RactorRailsShim.method(:_install_all_framework_patches).source_location
    src = File.readlines(file)
    src[(line - 1)..].take_while { |l| !l.strip.eql?("end") }.join
  end

  it "does not call NON_DISPATCHED patches from the dispatcher" do
    # These are called from their parent install methods, not the dispatcher.
    NON_DISPATCHED.each do |m|
      refute dispatcher_source.include?(m.to_s),
             "#{m} should not be called from _install_all_framework_patches"
    end
  end

  it "dispatcher source contains no hardcoded _install_*_patch call lines" do
    # After the refactor, the dispatcher should iterate the method table,
    # not list individual method names.
    hardcoded = dispatcher_source.scan(/^\s+_install_\w+_patch$/)
    assert hardcoded.empty?,
           "dispatcher should not hardcode _install_*_patch calls, found: #{hardcoded.inspect}"
  end
end
