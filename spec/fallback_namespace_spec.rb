# frozen_string_literal: true

# Specs for the namespaced fallback (Step 12):
#   - RactorRailsShim::FallbackIES is the shim's own module (not defined by
#     opening the ActiveSupport namespace).
#   - When the real ActiveSupport::IsolatedExecutionState is absent,
#     ActiveSupport::IsolatedExecutionState is aliased to
#     RactorRailsShim::FallbackIES (not defined inside the ActiveSupport
#     namespace).
#   - When the real AS IES is present, the alias is NOT created and the real
#     one is used untouched.
#
# The fallback's behavioural contract (round-trip, key?, delete, clear,
# per-thread isolation) is already covered by fallback_ies_spec.rb; this
# spec only asserts the *namespace* invariant.

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

  # --- RactorRailsShim::FallbackIES is the shim's own module ---

  it "RactorRailsShim::FallbackIES is defined (in the shim's namespace)" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      puts defined?(RactorRailsShim::FallbackIES)
      puts RactorRailsShim::FallbackIES.name
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "constant", lines[0],
      "RactorRailsShim::FallbackIES should be a defined constant"
    assert_equal "RactorRailsShim::FallbackIES", lines[1],
      "FallbackIES should live in the RactorRailsShim namespace, not ActiveSupport"
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

  # --- The alias is created only when AS IES is absent ---

  it "when AS is absent, ActiveSupport::IsolatedExecutionState aliases FallbackIES" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      # The alias should point at the SAME module object.
      puts ActiveSupport::IsolatedExecutionState.equal?(RactorRailsShim::FallbackIES)
      # The fallback's KEY constant is reachable via the alias too.
      puts ActiveSupport::IsolatedExecutionState::KEY.inspect
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "true", lines[0],
      "AS::IES should alias (same object) RactorRailsShim::FallbackIES when AS is absent"
    assert_equal ":active_support_execution_state_fallback", lines[1]
  end

  it "the alias is NOT a fresh definition inside the ActiveSupport namespace" do
    script = <<~'RUBY'
      require "ractor_rails_shim/fallback_ies"
      # Source location of [] should point at fallback_ies.rb (where
      # FallbackIES is defined), confirming AS::IES is an alias, not a
      # separately-defined module.
      src = ActiveSupport::IsolatedExecutionState.method(:[]).source_location&.first
      puts src
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    assert_match(/fallback_ies/, out,
      "AS::IES (alias) [] method source should be fallback_ies.rb")
  end

  # --- When AS is present, the real one wins, no alias ---

  it "when AS is present, the real AS IES is used (not the fallback)" do
    script = <<~'RUBY'
      require "active_support/isolated_execution_state"
      require "ractor_rails_shim/fallback_ies"
      # The real AS IES module should NOT be the same object as FallbackIES.
      puts ActiveSupport::IsolatedExecutionState.equal?(RactorRailsShim::FallbackIES)
      src = ActiveSupport::IsolatedExecutionState.method(:[]).source_location&.first
      puts src
    RUBY
    out, _err, status = run_subprocess_assertions(script)
    assert_equal 0, status.exitstatus
    lines = out.lines.map(&:chomp)
    assert_equal "false", lines[0],
      "real AS::IES should NOT be FallbackIES"
    assert_match(/active_support/, lines[1],
      "real AS::IES source should be active_support, not fallback_ies")
  end
end