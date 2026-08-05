# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the unified class_attribute heredoc (Issue #15, Step 15.2): the former
# two-mode `_class_attr_thread_methods` / `_class_attr_ractor_methods` pair
# collapsed into a single `_class_attr_methods` that calls
# `RactorRailsShim.storage_strategy.lookup/store`. The selected strategy
# (set once at install from `RunMode.thread?`) decides the backend.
class ClassAttributeDedupSpec < Minitest::Spec
  it "_class_attr_methods builds a reader+writer pair for the given method name" do
    body = RactorRailsShim._class_attr_methods(:my_attr, ':rrs_key_my_attr', "nil")
    # Defines the method under the given name, not the namespaced name
    assert_includes body, "def my_attr\n"
    assert_includes body, "def my_attr=(new_value)\n"
    # The reader delegates to the storage strategy
    assert_includes body, "RactorRailsShim.storage_strategy.lookup(self, :rrs_key_my_attr, nil)"
    # The writer delegates to the storage strategy
    assert_includes body, "RactorRailsShim.storage_strategy.store(self, :rrs_key_my_attr, new_value)"
  end

  it "_class_attr_methods with a different method name produces a different def" do
    body = RactorRailsShim._class_attr_methods(:other, ':rrs_key_other', "RactorRailsShim::EMPTY_CALLBACKS_HASH")
    assert_includes body, "def other\n"
    assert_includes body, "def other=(new_value)\n"
    # The __callbacks missing-slot default is inlined
    assert_includes body, "RactorRailsShim::EMPTY_CALLBACKS_HASH"
    assert_includes body, "RactorRailsShim.storage_strategy.lookup(self, :rrs_key_other, RactorRailsShim::EMPTY_CALLBACKS_HASH)"
  end

  it "there is a single helper (the two-mode pair is gone)" do
    refute RactorRailsShim.respond_to?(:_class_attr_thread_methods),
      "the thread-mode helper should be gone after the collapse"
    refute RactorRailsShim.respond_to?(:_class_attr_ractor_methods),
      "the ractor-mode helper should be gone after the collapse"
    assert RactorRailsShim.respond_to?(:_class_attr_methods),
      "the unified helper should exist"
  end
end