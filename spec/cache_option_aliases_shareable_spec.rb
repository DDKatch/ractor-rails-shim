# frozen_string_literal: true

# Regression spec: worker Ractors could not read ActiveSupport::Cache::
# OPTION_ALIASES (Rails freezes the Hash shallowly — the inner Arrays are
# unfrozen and unshareable), so every ActiveSupport::Cache::Store#fetch /
# #read / #write with an options hash died with
# Ractor::IsolationError: "can not access non-shareable objects in constant
# ActiveSupport::Cache::OPTION_ALIASES by non-main ractor".
#
# The next wall behind it was ActiveSupport::Cache::Coder's pack templates +
# deserializer registries (unfrozen Strings/Hashes read during entry
# deserialization in Coder#load).
#
# Both blocked low-level Rails.cache.fetch AND view fragment caching inside
# worker Ractors. The fix registers the constants in SHAREABLE_CONSTANTS so
# ConstantShareabilizer deep-freezes them at prepare_for_ractors! time.

require "minitest/autorun"
require "active_support"
require "active_support/cache"
require_relative "../lib/ractor_rails_shim/patches"

class CacheOptionAliasesShareableSpec < Minitest::Spec
  CODER_PATHS = %w[
    ActiveSupport::Cache::Coder::PACKED_TYPE_TEMPLATE
    ActiveSupport::Cache::Coder::PACKED_EXPIRES_AT_TEMPLATE
    ActiveSupport::Cache::Coder::PACKED_VERSION_LENGTH_TEMPLATE
    ActiveSupport::Cache::Coder::STRING_DESERIALIZERS
    ActiveSupport::Cache::Coder::STRING_ENCODINGS
  ]

  # Resolve "A::B::C" to the constant value without a shim helper.
  def const_value(path)
    path.split("::").inject(Object) { |mod, name| mod.const_get(name) }
  end

  it "registers OPTION_ALIASES in SHAREABLE_CONSTANTS" do
    assert_includes RactorRailsShim::SHAREABLE_CONSTANTS,
                    "ActiveSupport::Cache::OPTION_ALIASES",
                    "OPTION_ALIASES must stay registered — dropping it re-breaks cache access from worker Ractors"
  end

  it "deep-freezes the alias map into a Ractor-shareable twin" do
    # Snapshot + restore so the mutation does not leak into other specs.
    original = ActiveSupport::Cache::OPTION_ALIASES
    begin
      RactorRailsShim.make_constant_shareable!("ActiveSupport::Cache::OPTION_ALIASES")

      assert ActiveSupport::Cache::OPTION_ALIASES.frozen?
      # Shallow-freeze is not enough: every VALUE (Array) must be frozen too.
      ActiveSupport::Cache::OPTION_ALIASES.each_value do |aliases|
        assert aliases.frozen?,
               "OPTION_ALIASES values must be frozen — a frozen Hash with unfrozen Array values is still unshareable"
      end
      assert Ractor.shareable?(ActiveSupport::Cache::OPTION_ALIASES),
             "OPTION_ALIASES must be fully Ractor-shareable"
    ensure
      ActiveSupport::Cache.send(:remove_const, :OPTION_ALIASES)
      ActiveSupport::Cache.const_set(:OPTION_ALIASES, original)
    end
  end

  it "registers the Cache::Coder constants" do
    ([ "ActiveSupport::Cache::OPTION_ALIASES" ] + CODER_PATHS).each do |path|
      assert_includes RactorRailsShim::SHAREABLE_CONSTANTS, path,
                      "#{path} must stay registered — dropping it re-breaks cache access from worker Ractors"
    end
  end

  it "makes the OPTION_ALIASES + Coder constants Ractor-shareable" do
    coder_paths = %w[
      ActiveSupport::Cache::Coder::PACKED_TYPE_TEMPLATE
      ActiveSupport::Cache::Coder::PACKED_EXPIRES_AT_TEMPLATE
      ActiveSupport::Cache::Coder::PACKED_VERSION_LENGTH_TEMPLATE
      ActiveSupport::Cache::Coder::STRING_DESERIALIZERS
      ActiveSupport::Cache::Coder::STRING_ENCODINGS
    ]
    ([ "ActiveSupport::Cache::OPTION_ALIASES" ] + coder_paths).each do |path|
      RactorRailsShim.make_constant_shareable!(path)
      assert Ractor.shareable?(const_value(path)),
             "#{path} must be fully Ractor-shareable after make_constant_shareable!"
    end
  end

  it "lets a worker Ractor read the alias map without an IsolationError" do
    RactorRailsShim.make_constant_shareable!("ActiveSupport::Cache::OPTION_ALIASES")

    result = Ractor.new do
      ActiveSupport::Cache::OPTION_ALIASES[:expires_in]
    end
    assert_equal [ :expire_in, :expired_in ], result.value
  end
end
