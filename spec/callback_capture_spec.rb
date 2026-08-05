# frozen_string_literal: true

# Specs for Issue #13, Step 13.5: extract CallbackCapture from the
# RactorRailsShim god module (POODR §1 SRP). The callback-declaration
# capture machinery — _install_callback_declaration_capture!,
# _record_declared_callback, _freeze_declared_callbacks!,
# _read_action_filter_constraints, _read_ivar_or_warn — is one role
# collapsed onto the singleton. These specs pin the extracted object's
# contract directly so it is independently specable.
#
# The RactorRailsShim facade keeps delegating methods, so debug_funnel_spec
# keeps passing unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/callback_capture_spec.rb

require "minitest/autorun"
require "set"
require "active_support/isolated_execution_state"
require "active_support/callbacks"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class CallbackCaptureSpec < Minitest::Spec
  def self.test_order
    :alpha
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  # --- namespace ---

  it "RactorRailsShim::CallbackCapture is a Module" do
    assert_kind_of Module, RactorRailsShim::CallbackCapture
  end

  # --- record_declared_callback / freeze_declared_callbacks! ---

  it "record_declared_callback records a symbolic filter entry" do
    # Clear any prior state so the assertion is isolated.
    RactorRailsShim.remove_instance_variable(:@declared_callbacks) if RactorRailsShim.instance_variable_defined?(:@declared_callbacks)
    RactorRailsShim::CallbackCapture.record_declared_callback(12345, :before, :set_post, [:index], nil)
    table = RactorRailsShim.instance_variable_get(:@declared_callbacks)
    assert_kind_of Hash, table
    assert_includes table.keys, 12345
    entry = table[12345].last
    assert_equal :before, entry[:kind]
    assert_equal :set_post, entry[:filter]
    assert_equal [:index], entry[:only]
    assert_nil entry[:except]
  ensure
    RactorRailsShim.remove_instance_variable(:@declared_callbacks) if RactorRailsShim.instance_variable_defined?(:@declared_callbacks)
  end

  it "freeze_declared_callbacks! builds a shareable SHAREABLE_DECLARED_CALLBACKS constant" do
    RactorRailsShim.remove_instance_variable(:@declared_callbacks) if RactorRailsShim.instance_variable_defined?(:@declared_callbacks)
    RactorRailsShim::CallbackCapture.record_declared_callback(67890, :after, :audit, nil, [:destroy])
    RactorRailsShim::CallbackCapture.freeze_declared_callbacks!
    assert defined?(RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS), "constant should be defined"
    val = RactorRailsShim::SHAREABLE_DECLARED_CALLBACKS
    assert Ractor.shareable?(val), "SHAREABLE_DECLARED_CALLBACKS should be shareable"
    assert val.frozen?, "SHAREABLE_DECLARED_CALLBACKS should be frozen"
    assert_includes val.keys, 67890
  ensure
    RactorRailsShim.remove_instance_variable(:@declared_callbacks) if RactorRailsShim.instance_variable_defined?(:@declared_callbacks)
  end

  # --- read_action_filter_constraints ---

  it "read_action_filter_constraints reads @conditional_key and @actions when present" do
    fake_af = Object.new
    fake_af.instance_variable_set(:@conditional_key, :only)
    fake_af.instance_variable_set(:@actions, Set.new(["index", "show"].freeze).freeze)
    result = RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
    assert_equal :only, result[0]
    assert_equal [:index, :show], result[1]
  end

  it "read_action_filter_constraints returns [nil, nil] for a bare object (missing ivars)" do
    fake_af = Object.new
    result = RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
    assert_equal [nil, nil], result
  end

  it "read_action_filter_constraints funnels missing ivars through _swallow (labeled, debug=true)" do
    fake_af = Object.new
    RactorRailsShim.debug = true
    out = capture_stderr do
      result = RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
      assert_equal [nil, nil], result
    end
    assert_includes out, "[ractor_rails_shim]", "missing ivars should be funneled through _swallow"
    assert_includes out, "action filter constraints", "stderr should carry the action-filter label"
  ensure
    RactorRailsShim.debug = false
  end

  # --- read_ivar_or_warn ---

  it "read_ivar_or_warn returns the ivar value when defined" do
    obj = Object.new
    obj.instance_variable_set(:@probe, :value)
    assert_equal :value, RactorRailsShim::CallbackCapture.read_ivar_or_warn(obj, :@probe, "test label")
  end

  it "read_ivar_or_warn returns nil and warns (debug=true) when the ivar is missing" do
    obj = Object.new
    RactorRailsShim.debug = true
    out = capture_stderr do
      assert_nil RactorRailsShim::CallbackCapture.read_ivar_or_warn(obj, :@missing, "test label")
    end
    assert_includes out, "[ractor_rails_shim]"
    assert_includes out, "test label"
  ensure
    RactorRailsShim.debug = false
  end

  it "read_ivar_or_warn returns nil silently when the ivar is missing and debug is false" do
    obj = Object.new
    RactorRailsShim.debug = false
    out = capture_stderr do
      assert_nil RactorRailsShim::CallbackCapture.read_ivar_or_warn(obj, :@missing, "test label")
    end
    assert_empty out
  ensure
    RactorRailsShim.debug = false
  end

  # --- install_callback_declaration_capture! ---

  it "install_callback_declaration_capture! is idempotent via @callback_capture_installed" do
    # The real install aliases set_callback; we only assert idempotency here
    # (the second call is a no-op). Clear the flag first so the test is
    # isolated.
    RactorRailsShim.remove_instance_variable(:@callback_capture_installed) if RactorRailsShim.instance_variable_defined?(:@callback_capture_installed)
    RactorRailsShim::CallbackCapture.install_callback_declaration_capture!
    assert RactorRailsShim.instance_variable_get(:@callback_capture_installed),
           "flag should be set after install"
    # Second call must not raise and must remain installed.
    RactorRailsShim::CallbackCapture.install_callback_declaration_capture!
    assert RactorRailsShim.instance_variable_get(:@callback_capture_installed)
  ensure
    # Restore the original set_callback if we aliased it. The install aliases
    # _rrs_orig_set_callback → set_callback; restore so later specs see the
    # patched (not double-patched) method. Best-effort: if the alias was
    # already in place before this test, leave it.
    if defined?(::ActiveSupport::Callbacks::ClassMethods) &&
       ::ActiveSupport::Callbacks::ClassMethods.method_defined?(:_rrs_orig_set_callback)
      # already installed by a prior load — leave as-is
    end
  end

  # --- Facade delegation ---

  it "RactorRailsShim._record_declared_callback delegates to CallbackCapture.record_declared_callback" do
    delegated = false
    original = RactorRailsShim::CallbackCapture.method(:record_declared_callback)
    RactorRailsShim::CallbackCapture.define_singleton_method(:record_declared_callback) do |*args|
      delegated = true
    end
    RactorRailsShim._record_declared_callback(999, :before, :x, nil, nil)
    assert delegated
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:record_declared_callback, original)
  end

  it "RactorRailsShim._freeze_declared_callbacks! delegates to CallbackCapture.freeze_declared_callbacks!" do
    delegated = false
    original = RactorRailsShim::CallbackCapture.method(:freeze_declared_callbacks!)
    RactorRailsShim::CallbackCapture.define_singleton_method(:freeze_declared_callbacks!) do
      delegated = true
    end
    RactorRailsShim._freeze_declared_callbacks!
    assert delegated
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:freeze_declared_callbacks!, original)
  end

  it "RactorRailsShim._install_callback_declaration_capture! delegates to CallbackCapture.install_callback_declaration_capture!" do
    delegated = false
    original = RactorRailsShim::CallbackCapture.method(:install_callback_declaration_capture!)
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!) do
      delegated = true
    end
    RactorRailsShim._install_callback_declaration_capture!
    assert delegated
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:install_callback_declaration_capture!, original)
  end

  it "RactorRailsShim._read_action_filter_constraints delegates to CallbackCapture.read_action_filter_constraints" do
    delegated = false
    original = RactorRailsShim::CallbackCapture.method(:read_action_filter_constraints)
    RactorRailsShim::CallbackCapture.define_singleton_method(:read_action_filter_constraints) do |af|
      delegated = true
      [nil, nil]
    end
    RactorRailsShim._read_action_filter_constraints(Object.new)
    assert delegated
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:read_action_filter_constraints, original)
  end

  it "RactorRailsShim._read_ivar_or_warn delegates to CallbackCapture.read_ivar_or_warn" do
    delegated = false
    original = RactorRailsShim::CallbackCapture.method(:read_ivar_or_warn)
    RactorRailsShim::CallbackCapture.define_singleton_method(:read_ivar_or_warn) do |obj, ivar, label|
      delegated = true
    end
    RactorRailsShim._read_ivar_or_warn(Object.new, :@x, "label")
    assert delegated
  ensure
    RactorRailsShim::CallbackCapture.define_singleton_method(:read_ivar_or_warn, original)
  end

  # --- Issue #18: version-gated ActionFilter ivar reads ---

  # Step 18.1: install registers :action_filter_introspection in PATCH_VERSIONS

  it "install_callback_declaration_capture! registers :action_filter_introspection tagged 8.1" do
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.delete(:action_filter_introspection)
    RactorRailsShim.remove_instance_variable(:@callback_capture_installed) if RactorRailsShim.instance_variable_defined?(:@callback_capture_installed)
    RactorRailsShim::CallbackCapture.install_callback_declaration_capture!
    assert_includes RactorRailsShim::VersionPolicy::PATCH_VERSIONS, :action_filter_introspection,
                    "install should register :action_filter_introspection"
    assert_equal ["8.1"], RactorRailsShim::VersionPolicy::PATCH_VERSIONS[:action_filter_introspection]
  ensure
    RactorRailsShim::VersionPolicy::PATCH_VERSIONS.delete(:action_filter_introspection)
  end

  # Step 18.2: strict-mode raises on a missing ActionFilter ivar

  it "read_action_filter_constraints raises UnsupportedVersionError under :strict when an ivar is missing" do
    RactorRailsShim::VersionPolicy.policy = :strict
    fake_af = Object.new # no @conditional_key, no @actions
    assert_raises RactorRailsShim::VersionPolicy::UnsupportedVersionError do
      RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
    end
  ensure
    RactorRailsShim::VersionPolicy.policy = nil
  end

  it "read_action_filter_constraints returns [nil, nil] under :warn when an ivar is missing" do
    RactorRailsShim::VersionPolicy.policy = :warn
    fake_af = Object.new
    result = RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
    assert_equal [nil, nil], result
  ensure
    RactorRailsShim::VersionPolicy.policy = nil
  end

  it "read_action_filter_constraints returns the constraints under :strict when ivars are present" do
    RactorRailsShim::VersionPolicy.policy = :strict
    fake_af = Object.new
    fake_af.instance_variable_set(:@conditional_key, :except)
    fake_af.instance_variable_set(:@actions, Set.new(%w[create update].freeze).freeze)
    result = RactorRailsShim::CallbackCapture.read_action_filter_constraints(fake_af)
    assert_equal :except, result[0]
    assert_equal [:create, :update], result[1]
  ensure
    RactorRailsShim::VersionPolicy.policy = nil
  end

  it "read_ivar_or_warn raises UnsupportedVersionError under :strict when the ivar is missing" do
    RactorRailsShim::VersionPolicy.policy = :strict
    obj = Object.new
    assert_raises RactorRailsShim::VersionPolicy::UnsupportedVersionError do
      RactorRailsShim::CallbackCapture.read_ivar_or_warn(obj, :@missing, "test label")
    end
  ensure
    RactorRailsShim::VersionPolicy.policy = nil
  end
end