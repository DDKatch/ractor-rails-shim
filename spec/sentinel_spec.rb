# frozen_string_literal: true

# Regression specs for the nil-sentinel fix: the shim's IES-routed
# accessors previously used `return v unless v.nil?` to detect "no
# per-Ractor override." That made `Foo.x = nil` (or `= false`)
# indistinguishable from "never set," so the reader would silently fall
# through to the default/fallback. The fix uses `<storage>.key?(...)`
# so any explicit assignment — including `nil` and `false` — wins over
# the fallback.
#
# Run: ruby -Ilib -Ispec -e 'require "minitest/autorun"; require File.expand_path("spec/sentinel_spec.rb", __dir__)'

require "minitest/autorun"
require "active_support/class_attribute"
require "active_support/execution_wrapper"
require_relative "../lib/ractor_rails_shim/fallback_ies"
require_relative "../lib/ractor_rails_shim/patches"

# Minimal mattr_accessor stub on Module, so super in the prepended patch
# finds it (matches shim_spec.rb setup). In a real Rails app, ActiveSupport
# provides this; the shim's patched mattr_accessor calls super to delegate
# the actual cvar storage to Rails.
unless Module.method_defined?(:mattr_accessor, true)
  Module.module_eval do
    def mattr_accessor(name, default: nil, **)
      cv = "@@#{name}"
      class_variable_set(cv, default) unless class_variable_defined?(cv)
      define_singleton_method(name) { class_variable_get(cv) }
      define_singleton_method("#{name}=") { |v| class_variable_set(cv, v) }
    end
  end
end

RactorRailsShim.send(:install_class_attribute)
RactorRailsShim.send(:install_mattr_accessor)

# A module whose mattr we'll clobber with nil/false.
module SentinelTestMattr
  mattr_accessor :flag, default: true
  mattr_accessor :opt, default: :default_opt
end

# A class whose class_attribute we'll clobber with nil/false.
class SentinelTestClassAttr
  class_attribute :setting, default: :on
  class_attribute :list, default: []
end

describe "nil-sentinel fix" do
  it "mattr_accessor preserves an explicit nil over the default" do
    SentinelTestMattr.flag = nil
    assert_nil SentinelTestMattr.flag
    assert_nil SentinelTestMattr.flag
  ensure
    SentinelTestMattr.flag = true
  end

  it "mattr_accessor preserves an explicit false over the default" do
    SentinelTestMattr.flag = false
    assert_equal false, SentinelTestMattr.flag
  ensure
    SentinelTestMattr.flag = true
  end

  it "mattr_accessor preserves an explicit nil for a Symbol-default accessor" do
    SentinelTestMattr.opt = nil
    assert_nil SentinelTestMattr.opt
  ensure
    SentinelTestMattr.opt = :default_opt
  end

  it "class_attribute preserves an explicit nil over the default" do
    SentinelTestClassAttr.setting = nil
    assert_nil SentinelTestClassAttr.setting
  ensure
    SentinelTestClassAttr.setting = :on
  end

  it "class_attribute preserves an explicit false over the default" do
    SentinelTestClassAttr.setting = false
    assert_equal false, SentinelTestClassAttr.setting
  ensure
    SentinelTestClassAttr.setting = :on
  end

  it "class_attribute preserves an explicitly assigned empty array (vs default [])" do
    # The default is [] (a shareable frozen fallback). Assigning a NEW
    # empty array should override — distinct object identity from the
    # default. The nil-sentinel bug here would NOT regress (default is
    # also non-nil), but this guards the key? branch on Array values.
    assigned = []
    SentinelTestClassAttr.list = assigned
    assert_same assigned, SentinelTestClassAttr.list
  ensure
    SentinelTestClassAttr.list = []
  end
end