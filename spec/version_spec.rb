# frozen_string_literal: true

# Specs for the productionization infrastructure:
#   - Version detection (RactorRailsShim::Version: Gem::Version-based checks,
#     segment extraction, satisfies? comparisons).
#   - Version policy switch (:warn / :strict / :off) and UnsupportedVersionError.
#   - PATCH_VERSIONS registry: install_* methods register their tested versions,
#     and applicable_patches reports applied vs skipped.
#   - The callable / lock infrastructure classes (NoOpProc, Callable,
#     CallableConst, RequestCallable, NoOpLock, NoOpLogDev) that
#     make_app_shareable! uses to replace unshareable Procs and Mutexes — they
#     must be shareable once frozen and callable from a worker Ractor.
#
# These don't need Rails (only Ruby + the shim's own classes), so they run
# under the shim's own bundle alongside shim_spec.rb.

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# The callable/lock classes are defined on RactorRailsShim's singleton class
# (via module_eval inside `class << self`). Fetch them by name.
SC = RactorRailsShim.singleton_class
NoOpProc      = SC.const_get(:NoOpProc)
Callable      = SC.const_get(:Callable)
CallableConst = SC.const_get(:CallableConst)
RequestCallable = SC.const_get(:RequestCallable)
NoOpLock      = SC.const_get(:NoOpLock)
NoOpLogDev    = SC.const_get(:NoOpLogDev)

class VersionSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  # --- Version detection ---

  it "Version.ruby returns a Gem::Version matching RUBY_VERSION" do
    assert_kind_of Gem::Version, RactorRailsShim::Version.ruby
    assert_equal RUBY_VERSION, RactorRailsShim::Version.ruby.to_s
  end

  it "Version.ruby_segment returns major.minor" do
    seg = RactorRailsShim::Version.ruby_segment
    assert_match(/\A\d+\.\d+\z/, seg)
    assert_equal RUBY_VERSION.split(".").first(2).join("."), seg
  end

  it "Version.supported_ruby? is true on the developed-against Ruby" do
    # The shim requires Ruby >= 4.0.6; CI runs on 4.0.6+.
    assert RactorRailsShim::Version.supported_ruby?,
           "expected Ruby #{RUBY_VERSION} to be >= " \
           "#{RactorRailsShim::Version::SUPPORTED_RUBY}"
  end

  it "Version.rails is nil when Rails isn't loaded (boot.rb case)" do
    assert_nil RactorRailsShim::Version.rails
  end

  it "Version.rails_segment is nil when Rails isn't loaded" do
    assert_nil RactorRailsShim::Version.rails_segment
  end

  it "Version.supported_rails? is optimistic (true) when Rails isn't loaded yet" do
    # Can't decide → defer decision (don't block install before Rails loads).
    assert RactorRailsShim::Version.supported_rails?
  end

  it "Version.satisfies? compares a segment against a Gem::Requirement string" do
    assert RactorRailsShim::Version.satisfies?("8.1", "~> 8.1")
    assert RactorRailsShim::Version.satisfies?("8.1", ">= 7.0")
    refute RactorRailsShim::Version.satisfies?("7.1", "~> 8.1")
    assert RactorRailsShim::Version.satisfies?("8.2", "~> 8.0") # 8.2 in [8.0, 9.0)
    refute RactorRailsShim::Version.satisfies?("9.0", "~> 8.0") # 9.0 not < 9.0
    assert RactorRailsShim::Version.satisfies?("8.1.3", "~> 8.1")
    refute RactorRailsShim::Version.satisfies?(nil, "~> 8.1")
  end

  it "TESTED_RAILS is a frozen list including 8.1" do
    assert RactorRailsShim::Version::TESTED_RAILS.frozen?
    assert_includes RactorRailsShim::Version::TESTED_RAILS, "8.1"
  end

  # --- Version policy ---

  it "default version_policy is :warn" do
    assert_equal :warn, RactorRailsShim.version_policy
  end

  it ":off policy silences version-mismatch warnings" do
    RactorRailsShim.version_policy = :off
    out, _ = capture_io { RactorRailsShim.send(:_version_mismatch, "should be silent") }
    assert_empty out
  ensure
    RactorRailsShim.version_policy = :warn
  end

  it ":strict policy raises UnsupportedVersionError on mismatch" do
    RactorRailsShim.version_policy = :strict
    assert_raises(RactorRailsShim::UnsupportedVersionError) do
      RactorRailsShim.send(:_version_mismatch, "fatal now")
    end
  ensure
    RactorRailsShim.version_policy = :warn
  end

  it ":warn policy prints to $stderr on mismatch" do
    RactorRailsShim.version_policy = :warn
    out, err = capture_io { RactorRailsShim.send(:_version_mismatch, "warn me") }
    # :warn must NOT raise (that's :strict's job) and should emit the message.
    assert_match(/warn me/, out + err)
  end

  # --- Patch version registry ---

  it "install registers patches in PATCH_VERSIONS tagged with 8.1" do
    RactorRailsShim::PATCH_VERSIONS.clear
    RactorRailsShim.instance_variable_set(:@installed, false)
    # Reset idempotency flags so install re-registers (install is idempotent;
    # the flags guard re-application, but registration happens before the guard
    # returns for the _install_* methods — those are exercised via
    # prepare_for_ractors! below).
    RactorRailsShim.install
    # The early-boot patches (called directly by install) should be registered.
    assert_includes RactorRailsShim::PATCH_VERSIONS, :mattr_accessor
    assert_includes RactorRailsShim::PATCH_VERSIONS, :class_attribute
    assert_includes RactorRailsShim::PATCH_VERSIONS, :zeitwerk_registry
    assert_includes RactorRailsShim::PATCH_VERSIONS, :rails_module
    assert_includes RactorRailsShim::PATCH_VERSIONS, :shareable_constants
    assert_includes RactorRailsShim::PATCH_VERSIONS, :execution_wrapper
    # Each tagged with 8.1
    assert_equal ["8.1"], RactorRailsShim::PATCH_VERSIONS[:mattr_accessor]
  end

  it "prepare_for_ractors! registers the per-request accessor patches" do
    RactorRailsShim::PATCH_VERSIONS.clear
    RactorRailsShim.prepare_for_ractors!
    expected = %i[rack_request inflector parameter_encoding path_registry
                  abstract_controller error_reporter lookup_context i18n
                  template_handlers execution_context
                  request_parameter_parsers rack_utils]
    expected.each do |name|
      assert_includes RactorRailsShim::PATCH_VERSIONS, name,
                      "expected #{name} to be registered"
      assert_equal ["8.1"], RactorRailsShim::PATCH_VERSIONS[name]
    end
  end

  it "applicable_patches reports applied vs skipped by runtime Rails segment" do
    RactorRailsShim::PATCH_VERSIONS.clear
    RactorRailsShim._register_patch :sample_patch, "8.1"
    # Rails not loaded → seg is nil → all applied, none skipped (optimistic).
    report = RactorRailsShim.applicable_patches
    assert_includes report[:applied], :sample_patch
    assert_empty report[:skipped]
  end

  it "_register_patch is idempotent and dedupes version segments" do
    RactorRailsShim::PATCH_VERSIONS.clear
    RactorRailsShim._register_patch :dedup_test, "8.1"
    RactorRailsShim._register_patch :dedup_test, "8.1"
    RactorRailsShim._register_patch :dedup_test, "8.2"
    assert_equal ["8.1", "8.2"].sort, RactorRailsShim::PATCH_VERSIONS[:dedup_test].sort
  end

  # --- Callable / lock infrastructure ---

  it "NoOpProc returns nil and is shareable when frozen" do
    obj = NoOpProc.new
    obj.freeze
    assert Ractor.shareable?(obj)
    assert_nil obj.call(:anything, 1, 2)
  end

  it "Callable forwards call to target.method_name and is shareable when frozen" do
    target = Object.new
    def target.greet(name); "hi #{name}"; end
    target.freeze
    callable = Callable.new(target, :greet)
    callable.freeze
    assert Ractor.shareable?(callable)
    assert_equal "hi world", callable.call("world")
  end

  it "CallableConst returns a frozen constant value and is shareable when frozen" do
    val = true
    cc = CallableConst.new(val)
    cc.freeze
    assert Ractor.shareable?(cc)
    assert_equal true, cc.call(:ignored)
  end

  it "RequestCallable calls a method on its request arg and is shareable when frozen" do
    rc = RequestCallable.new(:upcase)
    rc.freeze
    assert Ractor.shareable?(rc)
    assert_equal "ABC", rc.call("abc")
  end

  it "NoOpLock yields without synchronizing and is shareable when frozen" do
    lock = NoOpLock.new
    lock.freeze
    assert Ractor.shareable?(lock)
    yielded = false
    result = lock.synchronize { yielded = true; :inner }
    assert yielded
    assert_equal :inner, result
    refute lock.locked?
    assert lock.try_lock
  end

  it "NoOpLogDev swallows writes and is shareable when frozen" do
    dev = NoOpLogDev.new
    dev.freeze
    assert Ractor.shareable?(dev)
    assert_equal dev, dev.write("x")
    assert_equal dev, dev.<<("y")
    assert_equal dev, dev.puts("z")
    assert_equal dev, dev.flush
    refute dev.closed?
    refute dev.tty?
  end

  # --- Cross-Ractor callability of the infrastructure ---

  it "Callable/NoOpLock are callable from a worker Ractor (frozen + shareable)" do
    port = Ractor::Port.new
    target = Object.new
    def target.echo(x); "echo:#{x}"; end
    target.freeze

    lock = NoOpLock.new.freeze
    callable = Callable.new(target, :echo).freeze

    r = Ractor.new(port, callable, lock) do |p, c, l|
      begin
        lock_result = l.synchronize { :ok }
        call_result = c.call(42)
        p.send({ lock: lock_result, call: call_result })
      rescue => e
        p.send("err: #{e.class}: #{e.message[0,80]}")
      end
    end
    result = port.receive
    assert_kind_of Hash, result, "got #{result.inspect}"
    assert_equal :ok, result[:lock]
    assert_equal "echo:42", result[:call]
  end
end
