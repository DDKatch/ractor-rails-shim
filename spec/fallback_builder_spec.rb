# frozen_string_literal: true

# Specs for Issue #13, Step 13.3: extract FallbackBuilder from the
# RactorRailsShim god module (POODR §1 SRP). The shareable-fallback builder —
# _build_shareable_fallback!, _try_make_shareable, _shareable_copy — is one
# role collapsed onto the singleton. These specs pin the extracted object's
# contract directly (the known-unshareable skip list + the default-fallback
# path), so the fallback builder is independently specable.
#
# The RactorRailsShim facade keeps delegating methods; reassign_const_spec
# keeps passing unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/fallback_builder_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

class FallbackBuilderSpec < Minitest::Spec
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

  it "RactorRailsShim::FallbackBuilder is a Module" do
    assert_kind_of Module, RactorRailsShim::FallbackBuilder
  end

  # --- shareable_copy ---

  it "shareable_copy returns a fresh dup for a Hash" do
    orig = { a: 1 }
    copy = RactorRailsShim::FallbackBuilder.shareable_copy(orig)
    assert_equal orig, copy
    refute_same orig, copy, "Hash copy should be a distinct object"
  end

  it "shareable_copy returns a fresh dup for an Array" do
    orig = [1, 2]
    copy = RactorRailsShim::FallbackBuilder.shareable_copy(orig)
    assert_equal orig, copy
    refute_same orig, copy, "Array copy should be a distinct object"
  end

  it "shareable_copy passes through non-container values" do
    val = Object.new
    assert_same val, RactorRailsShim::FallbackBuilder.shareable_copy(val)
    assert_equal :sym, RactorRailsShim::FallbackBuilder.shareable_copy(:sym)
  end

  # --- try_make_shareable: known-unshareable skip list ---

  it "try_make_shareable returns nil for __callbacks (known unshareable)" do
    val = { __callbacks: [] }
    assert_nil RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :__callbacks)
  end

  it "try_make_shareable returns nil for __validators (known unshareable)" do
    val = { x: 1 }
    assert_nil RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :__validators)
  end

  it "try_make_shareable returns nil for default_connection_handler (known unshareable)" do
    val = Object.new
    assert_nil RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :default_connection_handler)
  end

  # --- try_make_shareable: happy path ---

  it "try_make_shareable makes a plain mutable value shareable" do
    val = ["a", "b"]
    result = RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :list)
    assert Ractor.shareable?(result)
    assert result.frozen?
  end

  it "try_make_shareable returns nil and warns for an intrinsically unshareable value (Proc)" do
    val = ->(*) { :x }
    out = capture_stderr do
      assert_nil RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :proc_val)
    end
    assert_includes out, "ractor-rails-shim"
    assert_match(/Foo#proc_val/, out)
  end

  it "try_make_shareable suppresses the warning for a default (default: true)" do
    val = ->(*) { :x }
    out = capture_stderr do
      assert_nil RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :proc_val, default: true)
    end
    refute_includes out, "ractor-rails-shim", "default path should not warn"
  end

  # --- build! idempotency (Issue #24: flag lives on FallbackBuilder, not the facade) ---

  it "FallbackBuilder responds to built? and reset_built!" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :built?
    assert_respond_to RactorRailsShim::FallbackBuilder, :reset_built!
  end

  it "build! is idempotent via FallbackBuilder.@built (not the facade)" do
    RactorRailsShim::FallbackBuilder.reset_built!
    refute RactorRailsShim::FallbackBuilder.built?, "flag should be unset before first build"
    saved = RactorRailsShim::CLASS_ATTRIBUTES.dup
    RactorRailsShim::CLASS_ATTRIBUTES.replace([])

    result1 = RactorRailsShim::FallbackBuilder.build!
    assert RactorRailsShim::FallbackBuilder.built?, "flag should be set after first build"
    result2 = RactorRailsShim::FallbackBuilder.build!
    assert_nil result2, "second build should be a no-op (return nil)"
    assert RactorRailsShim::SHAREABLE_FALLBACK.frozen?
    assert Ractor.shareable?(RactorRailsShim::SHAREABLE_FALLBACK)
  ensure
    RactorRailsShim::CLASS_ATTRIBUTES.replace(saved) if saved
    RactorRailsShim::FallbackBuilder.reset_built!
  end

  # --- Facade delegation ---

  it "RactorRailsShim._build_shareable_fallback! delegates to FallbackBuilder.build!" do
    delegated = false
    original = RactorRailsShim::FallbackBuilder.method(:build!)
    RactorRailsShim::FallbackBuilder.define_singleton_method(:build!) do
      delegated = true
    end
    RactorRailsShim.send(:_build_shareable_fallback!)
    assert delegated
  ensure
    RactorRailsShim::FallbackBuilder.define_singleton_method(:build!, original)
  end

  it "RactorRailsShim._try_make_shareable delegates to FallbackBuilder.try_make_shareable" do
    delegated = false
    original = RactorRailsShim::FallbackBuilder.method(:try_make_shareable)
    RactorRailsShim::FallbackBuilder.define_singleton_method(:try_make_shareable) do |val, *args, **kw|
      delegated = true
    end
    RactorRailsShim._try_make_shareable(["a"], "Foo", :list)
    assert delegated
  ensure
    RactorRailsShim::FallbackBuilder.define_singleton_method(:try_make_shareable, original)
  end

  it "RactorRailsShim._shareable_copy delegates to FallbackBuilder.shareable_copy" do
    delegated = false
    original = RactorRailsShim::FallbackBuilder.method(:shareable_copy)
    RactorRailsShim::FallbackBuilder.define_singleton_method(:shareable_copy) do |val|
      delegated = true
    end
    RactorRailsShim._shareable_copy({})
    assert delegated
  ensure
    RactorRailsShim::FallbackBuilder.define_singleton_method(:shareable_copy, original)
  end

  # --- Issue #23: injected collaborators (POODR §2 Dependencies) ---
  #
  # FallbackBuilder must be constructible with the collaborators it
  # currently reaches through the RactorRailsShim facade by global name:
  #   - `safe_const_get`            (callable: `(path) -> value|nil`)
  #   - `replace_unshareable_procs` (callable: `(val) -> mutates val`)
  #   - `replace_locks_and_concurrent_maps` (callable: `(val) -> mutates`)
  #   - `reassign_shareable_const`  (callable: `(sym, value) -> reassigns`)
  #   - `class_attributes`          (CLASS_ATTRIBUTES array)
  #   - `class_attr_values`         (CLASS_ATTR_VALUES store, hash-like)
  #   - `shareable_mattr_defaults`  (SHAREABLE_MATTR_DEFAULTS array)
  #   - `storage`                   (IES storage, hash-like: storage[ies_key])
  # The seam is `configure(...)`; the defaults are the facade lookups so
  # existing call sites keep working. The `@built` idempotency
  # flag stays on the facade singleton here — Issue #24 moves it.

  it "responds to configure" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :configure
  end

  it "responds to reset_configuration" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :reset_configuration
  end

  it "responds to safe_const_get" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :safe_const_get
  end

  it "responds to replace_unshareable_procs" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :replace_unshareable_procs
  end

  it "responds to replace_locks_and_concurrent_maps" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :replace_locks_and_concurrent_maps
  end

  it "responds to reassign_shareable_const" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :reassign_shareable_const
  end

  it "responds to class_attributes" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :class_attributes
  end

  it "responds to class_attr_values" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :class_attr_values
  end

  it "responds to shareable_mattr_defaults" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :shareable_mattr_defaults
  end

  it "responds to storage" do
    assert_respond_to RactorRailsShim::FallbackBuilder, :storage
  end

  it "try_make_shareable routes val through the injected traversal helpers" do
    procs_called = []
    locks_called = []
    RactorRailsShim::FallbackBuilder.configure(
      replace_unshareable_procs: ->(v) { procs_called << v; v },
      replace_locks_and_concurrent_maps: ->(v) { locks_called << v; v }
    )
    val = ["a"]
    RactorRailsShim::FallbackBuilder.try_make_shareable(val, "Foo", :list)
    assert_includes procs_called, val, "replace_unshareable_procs should have been called with val"
    assert_includes locks_called, val, "replace_locks_and_concurrent_maps should have been called with val"
  ensure
    RactorRailsShim::FallbackBuilder.reset_configuration
  end

  it "build! reassigns via an injected reassign_shareable_const" do
    reassigned = []
    RactorRailsShim::FallbackBuilder.configure(
      reassign_shareable_const: ->(sym, val) { reassigned << [sym, val]; val },
      class_attributes: [],
      shareable_mattr_defaults: []
    )
    RactorRailsShim::FallbackBuilder.reset_built!
    RactorRailsShim::FallbackBuilder.build!
    syms = reassigned.map(&:first)
    assert_includes syms, :SHAREABLE_FALLBACK, "build! should reassign SHAREABLE_FALLBACK via the injected callable"
  ensure
    RactorRailsShim::FallbackBuilder.reset_built!
    RactorRailsShim::FallbackBuilder.reset_configuration
  end

  it "build! iterates an injected class_attributes registry" do
    iterated = []
    # A single class_attribute entry that yields no value (so the loop
    # runs but produces no fallback entry). The build! still completes and
    # reassigns the (empty) fallback.
    fake_registry = [["FakeOwner", :attr, :ies_key, nil]]
    RactorRailsShim::FallbackBuilder.configure(
      class_attributes: fake_registry,
      storage: { ies_key: nil },
      class_attr_values: {},
      shareable_mattr_defaults: [],
      safe_const_get: ->(name) { nil },
      reassign_shareable_const: ->(sym, val) { val }
    )
    RactorRailsShim::FallbackBuilder.reset_built!
    # Override the iteration by wrapping build! to capture the iteration
    # is hard; instead assert the build! returns a frozen shareable Hash
    # (the loop ran over the injected registry, produced an empty fallback
    # since the value was nil, and froze it).
    result = RactorRailsShim::FallbackBuilder.build!
    assert result.frozen?, "build! should return a frozen fallback Hash"
    assert Ractor.shareable?(result), "build! should return a shareable fallback"
  ensure
    RactorRailsShim::FallbackBuilder.reset_built!
    RactorRailsShim::FallbackBuilder.reset_configuration
  end

  it "build! reads the live value from an injected storage" do
    # storage[ies_key] returns a shareable value that becomes the fallback.
    val = Ractor.make_shareable(["live"])
    fake_registry = [["FakeOwner", :attr, :ies_key, nil]]
    RactorRailsShim::FallbackBuilder.configure(
      class_attributes: fake_registry,
      storage: { ies_key: val },
      class_attr_values: {},
      shareable_mattr_defaults: [],
      safe_const_get: ->(name) { nil },
      reassign_shareable_const: ->(sym, v) { v }
    )
    RactorRailsShim::FallbackBuilder.reset_built!
    result = RactorRailsShim::FallbackBuilder.build!
    assert_equal({ ies_key: val }, result, "fallback should read the live value from injected storage")
  ensure
    RactorRailsShim::FallbackBuilder.reset_built!
    RactorRailsShim::FallbackBuilder.reset_configuration
  end

  it "reset_configuration restores the facade-lookup defaults" do
    RactorRailsShim::FallbackBuilder.configure(
      safe_const_get: ->(p) { nil },
      replace_unshareable_procs: ->(v) { v },
      replace_locks_and_concurrent_maps: ->(v) { v },
      reassign_shareable_const: ->(s, v) { v },
      class_attributes: [],
      class_attr_values: {},
      shareable_mattr_defaults: [],
      storage: {}
    )
    refute_equal RactorRailsShim.method(:_safe_const_get), RactorRailsShim::FallbackBuilder.safe_const_get
    refute_equal RactorRailsShim.method(:_replace_unshareable_procs!), RactorRailsShim::FallbackBuilder.replace_unshareable_procs
    refute_equal RactorRailsShim.method(:_replace_locks_and_concurrent_maps!), RactorRailsShim::FallbackBuilder.replace_locks_and_concurrent_maps
    refute_equal RactorRailsShim.method(:_reassign_shareable_const), RactorRailsShim::FallbackBuilder.reassign_shareable_const
    refute_same RactorRailsShim::CLASS_ATTRIBUTES, RactorRailsShim::FallbackBuilder.class_attributes
    refute_same RactorRailsShim::CLASS_ATTR_VALUES, RactorRailsShim::FallbackBuilder.class_attr_values
    refute_same RactorRailsShim::SHAREABLE_MATTR_DEFAULTS, RactorRailsShim::FallbackBuilder.shareable_mattr_defaults
    refute_same RactorRailsShim.storage, RactorRailsShim::FallbackBuilder.storage

    RactorRailsShim::FallbackBuilder.reset_configuration
    assert_equal RactorRailsShim.method(:_safe_const_get), RactorRailsShim::FallbackBuilder.safe_const_get
    assert_equal RactorRailsShim.method(:_replace_unshareable_procs!), RactorRailsShim::FallbackBuilder.replace_unshareable_procs
    assert_equal RactorRailsShim.method(:_replace_locks_and_concurrent_maps!), RactorRailsShim::FallbackBuilder.replace_locks_and_concurrent_maps
    assert_equal RactorRailsShim.method(:_reassign_shareable_const), RactorRailsShim::FallbackBuilder.reassign_shareable_const
    assert_same RactorRailsShim::CLASS_ATTRIBUTES, RactorRailsShim::FallbackBuilder.class_attributes
    assert_same RactorRailsShim::CLASS_ATTR_VALUES, RactorRailsShim::FallbackBuilder.class_attr_values
    assert_same RactorRailsShim::SHAREABLE_MATTR_DEFAULTS, RactorRailsShim::FallbackBuilder.shareable_mattr_defaults
    assert_same RactorRailsShim.storage, RactorRailsShim::FallbackBuilder.storage
  ensure
    RactorRailsShim::FallbackBuilder.reset_configuration
  end
end