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

  # --- build! idempotency ---

  it "build! is idempotent via @fallback_built" do
    RactorRailsShim.remove_instance_variable(:@fallback_built) if RactorRailsShim.instance_variable_defined?(:@fallback_built)
    # First call builds; second is a no-op. With an empty CLASS_ATTRIBUTES
    # the fallback is an empty frozen shareable Hash.
    saved = RactorRailsShim::CLASS_ATTRIBUTES.dup
    RactorRailsShim::CLASS_ATTRIBUTES.replace([])

    result1 = RactorRailsShim::FallbackBuilder.build!
    assert RactorRailsShim.instance_variable_get(:@fallback_built), "flag should be set after first build"
    result2 = RactorRailsShim::FallbackBuilder.build!
    assert_nil result2, "second build should be a no-op (return nil)"
    assert RactorRailsShim::SHAREABLE_FALLBACK.frozen?
    assert Ractor.shareable?(RactorRailsShim::SHAREABLE_FALLBACK)
  ensure
    RactorRailsShim::CLASS_ATTRIBUTES.replace(saved) if saved
    RactorRailsShim.remove_instance_variable(:@fallback_built) if RactorRailsShim.instance_variable_defined?(:@fallback_built)
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
end