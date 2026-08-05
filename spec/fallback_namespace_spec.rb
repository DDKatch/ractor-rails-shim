# frozen_string_literal: true

# Specs for the namespace invariant after Issue #14, Step 14.3:
#
# The shim used to open the ActiveSupport namespace to alias
# `ActiveSupport::IsolatedExecutionState = RactorRailsShim::FallbackIES`
# when the real AS IES was absent. That namespace patch is now deleted:
# patch files route through `RactorRailsShim.storage` (selected once at load),
# so the shim no longer touches the ActiveSupport namespace.
#
# This spec pins the new invariant: the shim never defines
# `ActiveSupport::IsolatedExecutionState` itself.

require "minitest/autorun"
require "open3"

class FallbackNamespaceSpec < Minitest::Spec
  SHIM_LIB = File.expand_path("../lib", __dir__)

  def run_subprocess_assertions(script)
    out, err, status = Open3.capture3(
      { "RUBYOPT" => "-I#{SHIM_LIB}" },
      "ruby", "-e", script
    )
    [out, err, status]
  end

  # --- RactorRailsShim::FallbackIES is an alias for Storage::ThreadLocal ---

  it "RactorRailsShim::FallbackIES is defined (as an alias for Storage::ThreadLocal)" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      puts defined?(RactorRailsShim::FallbackIES)
      puts RactorRailsShim::FallbackIES.equal?(RactorRailsShim::Storage::ThreadLocal)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "constant", lines[0],
      "RactorRailsShim::FallbackIES should be a defined constant"
    assert_equal "true", lines[1],
      "FallbackIES should alias Storage::ThreadLocal"
  end

  it "FallbackIES provides the IES API ([] / []= / key? / delete / clear)" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      IES = RactorRailsShim::FallbackIES
      IES[:foo] = "bar"
      results = []
      results << IES[:foo]
      results << IES.key?(:foo)
      results << IES.key?(:missing)
      results << IES.delete(:foo)
      results << IES.key?(:foo)
      IES[:a] = 1; IES[:b] = 2
      IES.clear
      results << IES[:a]
      results << IES[:b]
      puts results.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    expected = ["bar", true, false, "bar", false, nil, nil]
    assert_equal expected.inspect, out.lines.first.chomp
  end

  # --- The namespace patch is gone: AS::IES is NOT defined by the shim ---

  it "when AS is absent, ActiveSupport::IsolatedExecutionState is NOT defined by the shim" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      puts defined?(ActiveSupport).inspect
      puts defined?(ActiveSupport::IsolatedExecutionState).inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "nil", lines[0],
      "the shim must NOT open the ActiveSupport namespace"
    assert_equal "nil", lines[1],
      "AS::IsolatedExecutionState must NOT be defined by the shim (no namespace patch)"
  end

  it "RactorRailsShim.storage is ThreadLocal when AS is absent" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      puts RactorRailsShim.storage.equal?(RactorRailsShim::Storage::ThreadLocal)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_equal "true", out.lines.first.chomp
  end

  # --- When AS is present, the real one wins, no alias ---

  it "when AS is present, RactorRailsShim.storage is Storage::IES (the real AS IES)" do
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/fallback_ies"
      puts RactorRailsShim.storage.equal?(RactorRailsShim::Storage::IES)
      # The real AS IES module should NOT be the same object as FallbackIES.
      puts ActiveSupport::IsolatedExecutionState.equal?(RactorRailsShim::FallbackIES)
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "true", lines[0],
      "RactorRailsShim.storage should be Storage::IES when AS is loaded"
    assert_equal "false", lines[1],
      "real AS::IES should NOT be FallbackIES"
  end
end