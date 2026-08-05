# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

# Pins the de-duplication of the thread-mode vs ractor-mode class_attribute
# heredocs. The reader/writer body for each mode is built by a single
# helper, called twice (once for the namespaced method name, once for the
# public name) so both paths share one body instead of two near-identical
# ~25-line heredoc copies.
class ClassAttributeDedupSpec < Minitest::Spec
  it "_class_attr_thread_methods builds a reader+writer pair for the given method name" do
    body = RactorRailsShim._class_attr_thread_methods(:my_attr, :__class_attr_my_attr, "nil")
    # Defines the method under the given name, not the namespaced name
    assert_includes body, "def my_attr\n"
    assert_includes body, "def my_attr=(new_value)\n"
    # The lookup key uses the namespaced name (storage key), not the method name
    assert_includes body, "__class_attr_my_attr"
    # The missing-slot default is inlined
    assert_includes body, "nil"
  end

  it "_class_attr_thread_methods with a different method name produces a different def" do
    body = RactorRailsShim._class_attr_thread_methods(:other, :__class_attr_other, "RactorRailsShim::EMPTY_CALLBACKS_HASH")
    assert_includes body, "def other\n"
    assert_includes body, "def other=(new_value)\n"
    assert_includes body, "RactorRailsShim::EMPTY_CALLBACKS_HASH"
  end

  it "_class_attr_ractor_methods builds a reader+writer pair for the given method name" do
    key_str = ':ractor_rails_shim_class_attr_42___class_attr_my_attr'
    body = RactorRailsShim._class_attr_ractor_methods(:my_attr, key_str)
    assert_includes body, "def my_attr\n"
    assert_includes body, "def my_attr=(new_value)\n"
    # The IES key literal is inlined
    assert_includes body, key_str
  end

  it "_class_attr_ractor_methods with a different method name produces a different def" do
    key_str = ':ractor_rails_shim_class_attr_99___class_attr_other'
    body = RactorRailsShim._class_attr_ractor_methods(:other, key_str)
    assert_includes body, "def other\n"
    assert_includes body, "def other=(new_value)\n"
  end
end