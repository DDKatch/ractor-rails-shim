# frozen_string_literal: true

# Specs for the `mattr_reader` / `cattr_reader` half of the mattr_accessor
# shim (added to fix `Ractor::IsolationError` on class-variable reads from
# worker Ractors — e.g. `ActiveRecord::Encryption.config`, which Rails
# declares via `mattr_reader :config`).
#
# `mattr_reader` is read-only, so only the reader is redefined to route
# through IES. The reader resolves, in priority order:
#   1. RactorRailsShim.storage[key]          (per-Ractor IES override)
#   2. main Ractor  -> the live `@@sym`      (workers can't read @@sym)
#   3. worker Ractor -> SHAREABLE_FALLBACK[key]   (built at prepare time from
#      the main-ractor `@@sym`) or, failing that, SHAREABLE_MATTR_DEFAULTS[key].
#
# These specs exercise branches 1-3 directly (the actual isolation fix) so
# they don't depend on Rails' exact `mattr_reader` default semantics.
#
# Run: ruby -Ilib -Ispec spec/mattr_reader_spec.rb

require "minitest/autorun"
require "active_support/isolated_execution_state"
require_relative "../lib/ractor_rails_shim/roles/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Minimal mattr_reader / cattr_reader / mattr_accessor / cattr_accessor
# stubs on Module so `super` inside the prepended patch finds them (matches
# mattr_split_spec's setup for mattr_accessor). The stub eagerly sets the
# class variable, mirroring the simplest Rails behavior.
unless Module.method_defined?(:mattr_reader, true)
  Module.module_eval do
    def mattr_reader(name, instance_reader: true, instance_accessor: true, default: nil, location: nil)
      cv = "@@#{name}"
      class_variable_set(cv, default) unless class_variable_defined?(cv)
      define_singleton_method(name) { class_variable_get(cv) }
      if instance_reader && instance_accessor
        define_method(name) { self.class.class_variable_get(cv) }
      end
    end

    def cattr_reader(name, instance_reader: true, instance_accessor: true, default: nil, location: nil)
      mattr_reader(name, instance_reader: instance_reader, instance_accessor: instance_accessor, default: default, location: location)
    end

    def mattr_accessor(name, instance_reader: true, instance_writer: true, instance_accessor: true, default: nil, **)
      cv = "@@#{name}"
      class_variable_set(cv, default) unless class_variable_defined?(cv)
      define_singleton_method(name) { class_variable_get(cv) }
      define_singleton_method("#{name}=") { |v| class_variable_set(cv, v) }
    end

    def cattr_accessor(name, instance_reader: true, instance_writer: true, instance_accessor: true, default: nil, **)
      mattr_accessor(name, instance_reader: instance_reader, instance_writer: instance_writer, instance_accessor: instance_accessor, default: default)
    end
  end
end

RactorRailsShim.send(:install_mattr_accessor)

class MattrReaderSpec < Minitest::Spec
  # A throwaway module per test so registry/class-variable mutations don't
  # leak across specs. Registered as a top-level constant so a worker Ractor
  # (which cannot receive the bare module object) can still reach it.
  def fresh_module
    mod = Module.new
    const_name = :"MattrReaderTest#{mod.object_id.abs}"
    Object.const_set(const_name, mod)
    mod.instance_variable_set(:@const_name, const_name)
    mod
  end

  def storage_key(mod)
    :"ractor_rails_shim_mattr_#{mod.name}_flag"
  end

  def teardown
    if defined?(@mod) && @mod && @mod.instance_variable_defined?(:@const_name)
      Object.send(:remove_const, @mod.instance_variable_get(:@const_name))
    end
    super
  end

  # Branch 1: a per-Ractor IES override wins in BOTH main and worker Ractors.
  it "reader returns the per-Ractor IES value when set" do
    @mod = fresh_module
    @mod.mattr_reader(:flag)
    key = storage_key(@mod)
    RactorRailsShim.storage[key] = :from_ies
    assert_equal :from_ies, @mod.flag
  ensure
    RactorRailsShim.storage.delete(key) if key
  end

  # Branch 2: in the main Ractor the live `@@flag` is readable.
  it "reader returns the live class variable in the main Ractor" do
    @mod = fresh_module
    @mod.mattr_reader(:flag)
    @mod.class_variable_set("@@flag", :from_cv)
    key = storage_key(@mod)
    refute RactorRailsShim.storage.key?(key), "precondition: no IES override"
    assert_equal :from_cv, @mod.flag
  end

  # Branch 3a: a worker Ractor cannot read `@@flag` and must fall back to
  # SHAREABLE_FALLBACK (built from the main-ractor value at prepare time).
  it "worker reader falls back to SHAREABLE_FALLBACK built from the main value" do
    @mod = fresh_module
    @mod.mattr_reader(:flag)
    @mod.class_variable_set("@@flag", :from_main)
    key = storage_key(@mod)

    # Simulate prepare_for_ractors! capturing the main value into the
    # shareable fallback constant (frozen + shareable).
    orig_fb = RactorRailsShim::SHAREABLE_FALLBACK
    fb = Ractor.make_shareable({ key => :from_main }.freeze)
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, fb)
    refute RactorRailsShim.storage.key?(key), "precondition: no IES override"

    const_name = @mod.instance_variable_get(:@const_name)
    result = Ractor.new(const_name) do |cn|
      Object.const_get(cn).flag
    end.value
    assert_equal :from_main, result,
                 "worker must read SHAREABLE_FALLBACK, not the unreadable @@flag"
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, orig_fb) if orig_fb
  end

  # Branch 3b: when SHAREABLE_FALLBACK is empty, a worker falls back to the
  # shareable default subset (SHAREABLE_MATTR_DEFAULTS) — the definition-time
  # default when it is shareable.
  it "worker reader falls back to SHAREABLE_MATTR_DEFAULTS for a shareable default" do
    @mod = fresh_module
    @mod.mattr_reader(:flag, default: :the_default)
    key = storage_key(@mod)
    # mattr_reader does not seed SHAREABLE_MATTR_DEFAULTS; seed it directly to
    # simulate the shareable-default fallback path.
    RactorRailsShim._seed_mattr_default(key, :the_default)
    assert_equal :the_default, RactorRailsShim::SHAREABLE_MATTR_DEFAULTS[key]

    orig_fb = RactorRailsShim::SHAREABLE_FALLBACK
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, Ractor.make_shareable({}.freeze))
    refute RactorRailsShim.storage.key?(key), "precondition: no IES override"

    const_name = @mod.instance_variable_get(:@const_name)
    result = Ractor.new(const_name) do |cn|
      Object.const_get(cn).flag
    end.value
    assert_equal :the_default, result
  ensure
    RactorRailsShim._reassign_shareable_const(:SHAREABLE_FALLBACK, orig_fb) if orig_fb
  end

  it "cattr_reader aliases mattr_reader (reader exists and routes through IES)" do
    @mod = fresh_module
    @mod.cattr_reader(:flag)
    key = storage_key(@mod)
    RactorRailsShim.storage[key] = :via_cattr
    assert_equal :via_cattr, @mod.flag
  ensure
    RactorRailsShim.storage.delete(key) if key
  end

  it "instance reader routes through IES (main Ractor)" do
    @mod = fresh_module
    @mod.mattr_reader(:flag)
    m = @mod
    klass = Class.new { include m }
    key = storage_key(@mod)
    RactorRailsShim.storage[key] = :inst_ies
    assert_equal :inst_ies, klass.new.flag
  ensure
    RactorRailsShim.storage.delete(key) if key
  end
end
