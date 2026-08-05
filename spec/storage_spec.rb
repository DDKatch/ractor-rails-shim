# frozen_string_literal: true

# Specs for the `Storage` role (Issue #14, Step 14.1): a pluggable
# key-value store contract (`[]`, `[]=`, `key?`, `delete`) with two
# implementations:
#
#   * `Storage::IES`        — delegates to ActiveSupport::IsolatedExecutionState
#   * `Storage::ThreadLocal` — the former FallbackIES body (thread-local Hash)
#
# `RactorRailsShim.storage` is set once at load: IES when AS is loaded,
# ThreadLocal otherwise. The indirection lets us delete the namespace alias
# patch (`ActiveSupport::IsolatedExecutionState = FallbackIES`) since the
# eval'd method bodies will call `RactorRailsShim.storage[...]` instead of the
# literal `ActiveSupport::IsolatedExecutionState[...]` (Step 14.2).

require "minitest/autorun"
require "open3"

class StorageSpec < Minitest::Spec
  SHIM_LIB = File.expand_path("../lib", __dir__)

  def run_subprocess_assertions(script)
    out, err, status = Open3.capture3(
      { "RUBYOPT" => "-I#{SHIM_LIB}" },
      "ruby", "-e", script
    )
    [out, err, status]
  end

  # --- Storage module + IES implementation (AS loaded) ---

  it "Storage is a module under RactorRailsShim" do
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/storage"
      puts RactorRailsShim::Storage.class
      puts RactorRailsShim::Storage::IES.class
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "Module", lines[0]
    assert_equal "Module", lines[1]
  end

  it "Storage::IES delegates to ActiveSupport::IsolatedExecutionState" do
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/storage"
      s = RactorRailsShim::Storage::IES
      s[:rrs_storage_test] = "v"
      r = []
      r << s[:rrs_storage_test]
      r << s.key?(:rrs_storage_test)
      r << s.key?(:rrs_storage_missing)
      r << s.delete(:rrs_storage_test)
      r << s.key?(:rrs_storage_test)
      puts r.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    expected = ["v", true, false, "v", false]
    assert_equal expected.inspect, out.lines.first.chomp
  end

  # --- Storage::ThreadLocal (no AS) ---

  it "Storage::ThreadLocal round-trips a value and supports key?/delete" do
    script = <<~'RUBY'
      require "ractor_rails_shim/storage"
      s = RactorRailsShim::Storage::ThreadLocal
      s[:foo] = "bar"
      r = []
      r << s[:foo]
      r << s.key?(:foo)
      r << s.key?(:missing)
      r << s.delete(:foo)
      r << s.key?(:foo)
      r << s[:foo]
      puts r.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    expected = ["bar", true, false, "bar", false, nil]
    assert_equal expected.inspect, out.lines.first.chomp
  end

  it "Storage::ThreadLocal isolates state per thread" do
    script = <<~'RUBY'
      require "ractor_rails_shim/storage"
      s = RactorRailsShim::Storage::ThreadLocal
      s[:shared] = "main"
      t = Thread.new do
        s[:shared] = "worker"
        s[:shared]
      end
      worker_val = t.value
      main_val = s[:shared]
      puts [worker_val, main_val].inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal ["worker", "main"].inspect, out.lines.first.chomp
  end

  it "Storage::ThreadLocal supports clear" do
    script = <<~'RUBY'
      require "ractor_rails_shim/storage"
      s = RactorRailsShim::Storage::ThreadLocal
      s[:a] = 1; s[:b] = 2
      s.clear
      r = [s[:a], s[:b]]
      puts r.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal [nil, nil].inspect, out.lines.first.chomp
  end

  # --- RactorRailsShim.storage selection ---

  it "RactorRailsShim.storage is Storage::IES when AS is loaded" do
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/storage"
      puts RactorRailsShim.storage.equal?(RactorRailsShim::Storage::IES)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal "true", out.lines.first.chomp
  end

  it "RactorRailsShim.storage is Storage::ThreadLocal when AS is absent" do
    script = <<~'RUBY'
      require "ractor_rails_shim/storage"
      puts RactorRailsShim.storage.equal?(RactorRailsShim::Storage::ThreadLocal)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal "true", out.lines.first.chomp
  end

  it "RactorRailsShim.storage honors the contract (round-trip via the indirection)" do
    script = <<~'RUBY'
      require "ractor_rails_shim/storage"
      st = RactorRailsShim.storage
      st[:rrs_indirection] = 42
      r = [st[:rrs_indirection], st.key?(:rrs_indirection), st.delete(:rrs_indirection), st.key?(:rrs_indirection)]
      puts r.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    expected = [42, true, 42, false]
    assert_equal expected.inspect, out.lines.first.chomp
  end
end