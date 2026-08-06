# frozen_string_literal: true

# Specs for `RactorRailsShim::FallbackIES` — now an alias for
# `RactorRailsShim::Storage::ThreadLocal` (Issue #14, Step 14.3).
#
# The standalone module body moved to `Storage::ThreadLocal`; this file keeps
# the `RactorRailsShim::FallbackIES` constant reachable as an alias. The
# namespace alias patch (`ActiveSupport::IsolatedExecutionState = FallbackIES`)
# has been deleted — the shim no longer opens the ActiveSupport namespace;
# patch files route through `RactorRailsShim.storage` instead.
#
# These specs run in a subprocess that does NOT require AS, asserting:
#   * `FallbackIES` is an alias for `Storage::ThreadLocal`
#   * `Storage::ThreadLocal` round-trips a value and supports key?/delete/clear
#   * per-thread isolation
#   * when AS is absent, `ActiveSupport::IsolatedExecutionState` is NOT
#     defined (the shim did not open the namespace)

require "minitest/autorun"
require "open3"

class FallbackIESSpec < Minitest::Spec
  SHIM_LIB = File.expand_path("../lib", __dir__)

  def run_subprocess_assertions(script)
    out, err, status = Open3.capture3(
      { "RUBYOPT" => "-I#{SHIM_LIB}" },
      "ruby", "-e", script
    )
    [out, err, status]
  end

  it "FallbackIES is an alias for Storage::ThreadLocal" do
    script = <<~'RUBY'
      require "ractor_rails_shim/roles/fallback_ies"
      puts RactorRailsShim::FallbackIES.equal?(RactorRailsShim::Storage::ThreadLocal)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal "true", out.lines.first.chomp
  end

  it "round-trips a value and supports key?/delete/clear" do
    script = <<~'RUBY'
      require "ractor_rails_shim/roles/fallback_ies"
      IES = RactorRailsShim::FallbackIES
      IES[:foo] = "bar"
      results = []
      results << IES[:foo]                       # "bar"
      results << IES.key?(:foo)                  # true
      results << IES.key?(:missing)              # false
      results << IES.delete(:foo)               # "bar"
      results << IES.key?(:foo)                  # false
      results << IES[:foo]                      # nil
      IES[:a] = 1; IES[:b] = 2
      IES.clear
      results << IES[:a]                         # nil
      results << IES[:b]                         # nil
      puts results.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    expected = ["bar", true, false, "bar", false, nil, nil, nil]
    assert_equal expected.inspect, out.lines.first.chomp
  end

  it "isolates state per thread" do
    script = <<~'RUBY'
      require "ractor_rails_shim/roles/fallback_ies"
      IES = RactorRailsShim::FallbackIES
      IES[:shared] = "main"
      t = Thread.new do
        IES[:shared] = "worker"
        IES[:shared]                                # "worker" (own thread)
      end
      worker_val = t.value
      main_val = IES[:shared]                       # "main" (unchanged)
      puts [worker_val, main_val].inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal ["worker", "main"].inspect, out.lines.first.chomp
  end

  it "when AS is absent, ActiveSupport::IsolatedExecutionState is NOT defined" do
    # The shim no longer opens the ActiveSupport namespace to alias the
    # fallback. Confirm AS::IES stays undefined when only the shim is loaded.
    script = <<~'RUBY'
      require "ractor_rails_shim/roles/fallback_ies"
      puts defined?(ActiveSupport::IsolatedExecutionState).inspect
      puts defined?(ActiveSupport).inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "nil", lines[0],
      "AS::IsolatedExecutionState must NOT be defined by the shim (no namespace patch)"
    assert_equal "nil", lines[1],
      "the ActiveSupport module itself must not be opened by the shim"
  end

  it "the real AS::IsolatedExecutionState is used when AS IS available" do
    # Sanity check: when AS is loaded, Storage::IES delegates to the real one,
    # and RactorRailsShim.storage is Storage::IES (not the fallback).
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/roles/fallback_ies"
      puts RactorRailsShim.storage.equal?(RactorRailsShim::Storage::IES)
      puts RactorRailsShim::Storage::IES.equal?(RactorRailsShim::FallbackIES)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "true", lines[0],
      "RactorRailsShim.storage should be Storage::IES when AS is loaded"
    assert_equal "false", lines[1],
      "Storage::IES is NOT the fallback (the fallback is ThreadLocal)"
  end
end