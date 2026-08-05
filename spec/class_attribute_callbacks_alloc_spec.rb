# frozen_string_literal: true

# Regression spec for the hot-path dead ternary in the thread-mode
# class_attribute reader. The thread-mode reader body previously had:
#
#   def __class_attr___callbacks
#     self.ancestors.each do |anc|
#       v = CLASS_ATTR_VALUES[:"...#{anc.object_id}___class_attr___callbacks"]
#       return v if CLASS_ATTR_VALUES.key?(...)
#     end
#     :__class_attr___callbacks == :__callbacks ? {} : nil
#   end
#
# The `:__class_attr___callbacks == :__callbacks` test is STATICALLY
# FALSE (the namespaced name is always `__class_attr_<name>`, never
# `<name>` itself), so the ternary always returns `nil` and the `{}`
# branch is dead code. The original INTENT was "if this is the
# `__callbacks` attribute, default to an empty Hash so callers like
# `__callbacks[:process_action]` don't NoMethodError on nil." That
# intent was broken because the check used the wrong name.
#
# The fix: check the PUBLIC `name` (not namespaced_name) at method-
# definition time and inline a frozen shared EMPTY_HASH constant
# instead of a per-call `{}`. This both restores the intent
# (`__callbacks` missing-slot returns `{}`) and removes the per-read
# Symbol interpolation + ternary allocation.
#
# Run: ruby -Ilib -Ispec -e 'require "minitest/autorun"; require File.expand_path("spec/class_attribute_callbacks_alloc_spec.rb", dir__)'

require "minitest/autorun"
require "active_support/class_attribute"
require "active_support/execution_wrapper"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# This spec exercises the THREAD-MODE class_attribute reader branch,
# which is selected at `install_class_attribute` time by
# `RactorRailsShim.thread_mode?`. Setting thread_mode globally would
# leak into other spec files (shim_spec, version_spec) that load
# afterward in the same process and expect ractor-mode behavior. To
# stay isolated, we fork a child process, set thread_mode + install
# the patch + define the probe class there, run the assertions, and
# report the result back via a pipe. The parent translates the child's
# exit code + stdout into minitest assertions.
#
# Run: ruby -Ilib -Ispec -e 'require "minitest/autorun"; require File.expand_path("spec/class_attribute_callbacks_alloc_spec.rb", dir__)'

describe "thread-mode class_attribute __callbacks missing-slot default" do
  # Absolute paths to the shim's lib files, computed in the parent
  # (where __dir__ resolves correctly) and substituted into the child
  # script. The child runs via `ruby -e`, so `require_relative` won't
  # work there — we use `require` with absolute paths instead.
  SHIM_LIB = File.expand_path("../lib", __dir__)

  # The child-process script. Runs in a fork where setting thread_mode
  # and re-installing the class_attribute patch affects only the child.
  # Single-quoted heredoc (<<~'RUBY') so the parent doesn't interpolate
  # the child's `#{...}` expressions; we inject SHIM_LIB via plain
  # string substitution before running.
  CHILD_SCRIPT = <<~'RUBY'
    $LOAD_PATH.unshift("__SHIM_LIB__")
    require "active_support/class_attribute"
    require "active_support/execution_wrapper"
    require "ractor_rails_shim/fallback_ies"
    require "ractor_rails_shim/patches"

    RactorRailsShim.thread_mode = true
    RactorRailsShim.send(:install_class_attribute)

    class ThreadModeCallbacksProbe
      class_attribute :__callbacks, default: {}
    end

    prefix = "___class_attr___callbacks"
    RactorRailsShim::CLASS_ATTR_VALUES.delete_if { |k, _| k.to_s.include?(prefix) }

    # Test 1: returns an empty Hash (not nil)
    v = ThreadModeCallbacksProbe.__callbacks
    raise "TEST1: expected Hash, got #{v.inspect}" unless v.is_a?(Hash) && v.empty?

    # Test 2: same object across calls + frozen + shareable + the constant
    a = ThreadModeCallbacksProbe.__callbacks
    b = ThreadModeCallbacksProbe.__callbacks
    raise "TEST2: expected same object, got #{a.object_id} vs #{b.object_id}" unless a.equal?(b)
    raise "TEST2: expected frozen, got mutable" unless a.frozen?
    raise "TEST2: expected shareable" unless Ractor.shareable?(a)
    raise "TEST2: expected EMPTY_CALLBACKS_HASH constant" unless a.equal?(RactorRailsShim::EMPTY_CALLBACKS_HASH)

    puts "OK"
  RUBY

  it "returns an empty frozen Hash (the shared constant) when no ancestor has a registered value" do
    script = CHILD_SCRIPT.sub("__SHIM_LIB__", SHIM_LIB)
    output = IO.popen(["ruby", "-e", script], err: [:child, :out], &:read)
    assert_equal "OK\n", output,
      "thread-mode __callbacks missing-slot default child script failed:\n#{output}"
  end
end