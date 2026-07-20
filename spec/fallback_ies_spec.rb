# frozen_string_literal: true

# Specs for `RactorRailsShim::FallbackIES` — the thread-local fallback used
# when `ActiveSupport::IsolatedExecutionState` is not available. In a normal
# Rails app the real AS IES is used, so this spec exercises the fallback in a
# subprocess that does NOT require AS. The subprocess asserts:
#
#   * `FallbackIES[key] = v` then `FallbackIES[key]` round-trips
#   * `key?` / `delete` / `clear` behave per the AS API
#   * per-thread isolation (one thread's writes aren't visible to another)
#   * the fallback module is actually the one loaded from `fallback_ies.rb`
#     (i.e. AS was NOT loaded in the subprocess)
#
# Run: ruby -Ilib -Ispec spec/fallback_ies_spec.rb

require "minitest/autorun"
require "open3"

class FallbackIESSpec < Minitest::Spec
  # The fallback is only defined when AS::IsolatedExecutionState is NOT
  # defined. In the shim's own test process (which loads AS for the other
  # specs), the fallback module is therefore NOT loaded. We run the actual
  # assertions in a fresh Ruby subprocess that doesn't load AS, and assert
  # against its stdout/stderr/exit code.
  SHIM_LIB = File.expand_path("../lib", __dir__)

  def run_subprocess_assertions(script)
    out, err, status = Open3.capture3(
      { "RUBYOPT" => "-I#{SHIM_LIB}" },
      "ruby", "-e", script
    )
    [out, err, status]
  end

  it "the fallback module is loaded when AS is not available" do
    # The fallback file defines `ActiveSupport::IsolatedExecutionState` itself
    # (guarded by `unless defined?(...)` at require time). So after requiring
    # ONLY fallback_ies (not active_support), the module IS defined but it's
    # the fallback, not the real AS one. Distinguish via:
    #   1. the fallback's KEY constant value
    #   2. the source location of the [] method (fallback_ies.rb vs active_support)
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      mod = ActiveSupport::IsolatedExecutionState
      key = mod::KEY
      src = mod.method(:[]).source_location
      puts "KEY=#{key.inspect}"
      puts "SRC=#{src.inspect}"
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "KEY=:active_support_execution_state_fallback", lines[0]
    assert_match(/fallback_ies/, lines[1],
      "the loaded IES should be the fallback, not the real AS one")
  end

  it "round-trips a value and supports key?/delete/clear" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      IES = ActiveSupport::IsolatedExecutionState
      IES[:foo] = "bar"
      results = []
      results << IES[:foo]                       # "bar"
      results << IES.key?(:foo)                  # true
      results << IES.key?(:missing)              # false
      results << IES.delete(:foo)                # "bar"
      results << IES.key?(:foo)                  # false
      results << IES[:foo]                       # nil
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
      require "ractor_rails_shim/fallback_ies"
      IES = ActiveSupport::IsolatedExecutionState
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

  it "the real AS::IsolatedExecutionState is used when AS IS available" do
    # Sanity check: when AS is loaded, the fallback is NOT defined, and the
    # real AS IES is used. This guards against the fallback accidentally
    # shadowing AS in real Rails apps.
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/fallback_ies"
      # The fallback file's `unless defined?(...)` guard should have skipped
      # redefining the module. Confirm by checking the source file path of
      # the IES module — it should point at active_support, not fallback_ies.
      method = ActiveSupport::IsolatedExecutionState.method(:[])
      puts method.source_location&.first
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_match(/active_support/, out,
      "real AS::IsolatedExecutionState should be used when AS is loaded")
    refute_match(/fallback_ies/, out,
      "fallback_ies should NOT shadow the real AS IES")
  end
end