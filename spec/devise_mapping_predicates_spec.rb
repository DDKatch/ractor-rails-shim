# frozen_string_literal: true

# Specs for Issue #7: replace the fully-dynamic `DeviseMappingSnapshot#x?`
# predicate dispatch with explicit predicate methods for Devise's known
# module set, while KEEPING `method_missing` as a fallback for custom
# modules added via `Devise.add_module` by third-party gems.
#
# The POODR critique (CODE_REVIEW.md #7): the dynamic `method_missing`
# pattern hides what API the object actually exposes — a reader can't tell
# which predicates are real without grepping Devise. Defining the standard
# set explicitly makes the message-based contract visible (and
# `method_defined?` returns true for them, so they're real methods, not
# synthesized on read), while the retained fallback preserves
# extensibility for custom modules.
#
# Contract pinned here:
#   1. Each of Devise's 10 standard modules gets a real `<module>?` method.
#   2. Each returns true iff the module Symbol is in `@modules`.
#   3. `method_defined?(:<module>?)` is true for the standard set (proving
#      they're real methods, not method_missing synthesis).
#   4. `method_missing` still answers `custom?` for non-standard modules
#      (extensibility preserved).
#   5. `respond_to_missing?` still returns true for `x?` predicates so
#      `respond_to?(:anything?)` keeps working.
#   6. `authenticatable?` (already explicit, regex-based) is unchanged.
#
# Run: bundle exec ruby -Ilib -Ispec spec/devise_mapping_predicates_spec.rb

require "minitest/autorun"
require "ractor_rails_shim/patches"

class DeviseMappingPredicatesSpec < Minitest::Spec
  SC = RactorRailsShim.singleton_class
  Snapshot = SC.const_get(:DeviseMappingSnapshot)

  # The 10 standard Devise modules from devise-5.0.4/lib/devise/modules.rb.
  # `authenticatable?` is handled separately (regex-based, already explicit).
  STANDARD_MODULES = %i[
    database_authenticatable
    rememberable
    omniauthable
    recoverable
    registerable
    validatable
    confirmable
    lockable
    timeoutable
    trackable
  ].freeze

  # Build a Snapshot from a fake mapping carrying the given module list.
  # Avoids requiring the real devise gem; stubs a minimal ::Devise constant
  # so the snapshot's `::Devise::FailureApp` / `::Devise::NO_INPUT` refs
  # resolve.
  def snapshot_with(modules)
    fake_devise = Module.new
    fake_devise.const_set(:FailureApp, Class.new)
    fake_devise.const_set(:NO_INPUT, [].freeze)
    Object.const_set(:Devise, fake_devise) unless defined?(::Devise)
    had_devise = defined?(::Devise)

    mapping = Object.new
    mapping.define_singleton_method(:name) { :users }
    mapping.define_singleton_method(:to) { Class.new }
    mapping.define_singleton_method(:instance_variable_get) do |iv|
      case iv.to_s
      when /router_name|singular|scoped_path|path|path_prefix|format|sign_out_via|failure_app/ then nil
      else super(iv)
      end
    end
    mapping.define_singleton_method(:modules) { modules }
    mapping.define_singleton_method(:strategies) { [] }
    mapping.define_singleton_method(:routes) { [] }
    mapping.define_singleton_method(:used_helpers) { [] }
    mapping.define_singleton_method(:controllers) { {} }

    Snapshot.new(mapping)
  ensure
    Object.send(:remove_const, :Devise) unless had_devise
  end

  # --- explicit predicate methods exist on the class ---

  STANDARD_MODULES.each do |mod|
    it "DeviseMappingSnapshot defines a real ##{mod}? method (not method_missing)" do
      assert Snapshot.method_defined?("#{mod}?"),
        "##{mod}? should be a real method (method_defined? true), not synthesized via method_missing"
    end
  end

  # --- predicate truthiness follows @modules membership ---

  it "standard predicates return true when their module is present" do
    snap = snapshot_with(STANDARD_MODULES)
    STANDARD_MODULES.each do |mod|
      assert snap.public_send("#{mod}?"),
        "##{mod}? should be true when :#{mod} is in modules"
    end
  end

  it "standard predicates return false when their module is absent" do
    snap = snapshot_with([])
    STANDARD_MODULES.each do |mod|
      refute snap.public_send("#{mod}?"),
        "##{mod}? should be false when :#{mod} is not in modules"
    end
  end

  it "a partial module set answers only the present predicates true" do
    snap = snapshot_with(%i[confirmable rememberable])
    assert snap.confirmable?
    assert snap.rememberable?
    refute snap.lockable?
    refute snap.trackable?
  end

  # --- authenticatable? (already explicit, regex-based) is unchanged ---

  it "authenticatable? is true for :database_authenticatable" do
    snap = snapshot_with(%i[database_authenticatable])
    assert snap.authenticatable?
  end

  it "authenticatable? is false when no authenticatable module is present" do
    snap = snapshot_with(%i[trackable])
    refute snap.authenticatable?
  end

  # --- method_missing fallback preserved for custom modules ---

  it "method_missing still answers custom-module predicates (extensibility)" do
    snap = snapshot_with(%i[my_custom_module])
    assert snap.my_custom_module?,
      "custom :my_custom_module? should be answered via method_missing fallback"
  end

  it "method_missing returns false for an absent custom module" do
    snap = snapshot_with(%i[other])
    refute snap.my_custom_module?,
      "absent custom :my_custom_module? should be false via method_missing"
  end

  # --- respond_to_missing? still covers x? predicates ---

  it "respond_to? returns true for any x? predicate (standard or custom)" do
    snap = snapshot_with([])
    assert snap.respond_to?(:confirmable?)
    assert snap.respond_to?(:some_unknown_module?)
  end

  it "respond_to? returns false for non-predicate unknown methods" do
    snap = snapshot_with([])
    refute snap.respond_to?(:some_non_predicate_method)
  end

  # --- shareability preserved (the whole point of the snapshot) ---

  it "a frozen snapshot with explicit predicates is still Ractor-shareable" do
    snap = snapshot_with(STANDARD_MODULES)
    Ractor.make_shareable(snap)
    assert Ractor.shareable?(snap),
      "DeviseMappingSnapshot with explicit predicates must remain shareable"
  end
end