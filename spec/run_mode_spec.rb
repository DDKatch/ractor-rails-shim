# frozen_string_literal: true

# Specs for the extracted RunMode sub-domain (Issue #6: move ENV["SERVER"] /
# @thread_mode detection out of `install`). Per POODR, deciding which mode
# the shim runs in (Ractor mode vs thread-server mode for Puma/Falcon/Thin/
# Webrick) is a *configuration* responsibility, distinct from the install
# orchestration that consumes the decision. It is extracted into
# RactorRailsShim::RunMode so it is independently specable, while the
# RactorRailsShim facade keeps `thread_mode?` / `thread_mode=` delegates for
# backward compatibility.
#
# The contract being pinned:
#   - RunMode defaults to Ractor (non-thread) mode when never configured.
#   - RunMode is explicitly settable via `RunMode.thread = true`.
#   - RunMode can be detected from the ambient ENV["SERVER"] via
#     `RunMode.detect_from_env`, which returns true for puma|falcon|thin|
#     webrick|thread* and false otherwise (including when SERVER is unset).
#   - Explicit configuration wins over ENV detection; once explicitly set,
#     ENV no longer affects the predicate (install's old `unless defined?`
#     guard, lifted into the object).
#   - The RactorRailsShim facade still answers `thread_mode?` and
#     `thread_mode=` by delegating to RunMode, so existing call sites
#     (patches/class_attribute.rb, patches/active_support.rb, specs that
#     set `RactorRailsShim.thread_mode = true`) keep working unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/run_mode_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class RunModeSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # Each test must start from an unconfigured RunMode so the `explicit wins
  # over ENV` invariant is testable. Reset both the RunMode state and the
  # facade's delegate cache.
  def reset_run_mode!
    RactorRailsShim::RunMode.reset
  end

  def with_env(server)
    saved = ENV["SERVER"]
    ENV["SERVER"] = server
    yield
  ensure
    ENV["SERVER"] = saved
  end

  # --- module existence + namespace ---

  it "RactorRailsShim::RunMode is a Module" do
    assert_kind_of Module, RactorRailsShim::RunMode
  end

  it "RunMode answers a thread? predicate" do
    reset_run_mode!
    assert_respond_to RactorRailsShim::RunMode, :thread?
  end

  # --- default state ---

  it "RunMode defaults to false (Ractor mode) when never configured" do
    reset_run_mode!
    refute RactorRailsShim::RunMode.thread?,
      "RunMode.thread? should default to false (Ractor mode) when unconfigured"
  end

  # --- explicit configuration ---

  it "RunMode is explicitly settable via thread= true" do
    reset_run_mode!
    RactorRailsShim::RunMode.thread = true
    assert RactorRailsShim::RunMode.thread?,
      "RunMode.thread? should be true after RunMode.thread = true"
  end

  it "RunMode is explicitly settable back to false" do
    reset_run_mode!
    RactorRailsShim::RunMode.thread = true
    assert RactorRailsShim::RunMode.thread?
    RactorRailsShim::RunMode.thread = false
    refute RactorRailsShim::RunMode.thread?,
      "RunMode.thread? should be false after RunMode.thread = false"
  end

  # --- ENV detection ---

  it "RunMode.detect_from_env returns true for puma" do
    with_env("puma") do
      assert RactorRailsShim::RunMode.detect_from_env,
        "detect_from_env should return true for SERVER=puma"
    end
  end

  it "RunMode.detect_from_env returns true for falcon" do
    with_env("falcon") do
      assert RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns true for thin" do
    with_env("thin") do
      assert RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns true for webrick" do
    with_env("webrick") do
      assert RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns true for thread* (case-insensitive)" do
    with_env("Threads") do
      assert RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env is case-insensitive on PUMA" do
    with_env("PUMA") do
      assert RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns false for an unrecognized SERVER" do
    with_env("nginx") do
      refute RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns false when SERVER is unset" do
    with_env(nil) do
      refute RactorRailsShim::RunMode.detect_from_env
    end
  end

  it "RunMode.detect_from_env returns false for empty SERVER" do
    with_env("") do
      refute RactorRailsShim::RunMode.detect_from_env
    end
  end

  # --- explicit wins over ENV ---

  it "explicit true wins over an absent ENV SERVER (detect is not consulted)" do
    reset_run_mode!
    with_env(nil) do
      RactorRailsShim::RunMode.thread = true
      assert RactorRailsShim::RunMode.thread?
    end
  end

  it "explicit false wins over a thread-server ENV SERVER" do
    reset_run_mode!
    with_env("puma") do
      RactorRailsShim::RunMode.thread = false
      refute RactorRailsShim::RunMode.thread?,
        "explicit false must shadow ENV=puma (the old `unless defined?` guard)"
    end
  end

  it "explicit true wins over a non-thread ENV SERVER" do
    reset_run_mode!
    with_env("ractor") do
      RactorRailsShim::RunMode.thread = true
      assert RactorRailsShim::RunMode.thread?
    end
  end

  # --- resolve! (the install-time decision) ---

  it "resolve! picks up ENV when no explicit config has been set" do
    reset_run_mode!
    with_env("puma") do
      RactorRailsShim::RunMode.resolve!
      assert RactorRailsShim::RunMode.thread?,
        "resolve! should detect ENV=puma when no explicit config is set"
    end
  end

  it "resolve! does NOT override an explicit config (true preserved)" do
    reset_run_mode!
    RactorRailsShim::RunMode.thread = true
    with_env("puma") do
      RactorRailsShim::RunMode.resolve!
      assert RactorRailsShim::RunMode.thread?
    end
  end

  it "resolve! does NOT override an explicit config (false preserved under puma)" do
    reset_run_mode!
    RactorRailsShim::RunMode.thread = false
    with_env("puma") do
      RactorRailsShim::RunMode.resolve!
      refute RactorRailsShim::RunMode.thread?
    end
  end

  it "resolve! is idempotent: calling twice yields the same answer" do
    reset_run_mode!
    with_env("puma") do
      RactorRailsShim::RunMode.resolve!
      first = RactorRailsShim::RunMode.thread?
      RactorRailsShim::RunMode.resolve!
      second = RactorRailsShim::RunMode.thread?
      assert_equal first, second
      assert second, "expected puma to resolve to thread mode"
    end
  end

  # --- facade delegation (backward compatibility) ---

  it "RactorRailsShim.thread_mode? delegates to RunMode.thread?" do
    reset_run_mode!
    RactorRailsShim::RunMode.thread = true
    assert RactorRailsShim.thread_mode?,
      "facade thread_mode? should delegate to RunMode.thread?"
  ensure
    reset_run_mode!
  end

  it "RactorRailsShim.thread_mode= delegates to RunMode.thread=" do
    reset_run_mode!
    RactorRailsShim.thread_mode = true
    assert RactorRailsShim::RunMode.thread?,
      "facade thread_mode= should delegate to RunMode.thread="
  ensure
    reset_run_mode!
  end

  it "install no longer reads @thread_mode directly (delegates to RunMode)" do
    reset_run_mode!
    # After refactor, install should not own @thread_mode state. Prove the
    # state lives on RunMode by setting it there and confirming install's
    # branch selection follows. We can't easily observe which branch install
    # took without stubbing the install_* methods, so instead assert the
    # invariant directly: install does not define @thread_mode on the
    # RactorRailsShim singleton.
    refute RactorRailsShim.instance_variable_defined?(:@thread_mode),
      "install should not own @thread_mode after refactor; it lives on RunMode"
  ensure
    reset_run_mode!
  end
end