# frozen_string_literal: true

# Specs for the stdlib unicode_normalize worker patch. The module is always
# loaded by the patch (stdlib, no gem), so both halves always run:
#   * freeze step — REGEXP_* / UNICODE_ENCODINGS become shareable
#   * normalize / normalized? — main keeps the memoizing NF-hashes, workers
#     recompute per match on per-Ractor memo hashes
#
# Run: bundle exec ruby -Ilib -Ispec spec/unicode_normalize_patch_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class UnicodeNormalizePatchSpec < Minitest::Spec
  before do
    RactorRailsShim._install_unicode_normalize_patch
  end

  it "is idempotent and registers in the version policy" do
    first = RactorRailsShim._install_unicode_normalize_patch
    second = RactorRailsShim._install_unicode_normalize_patch

    assert first.nil? || first == true
    assert_nil second, "the second install must be a guarded no-op"
    assert RactorRailsShim::VersionPolicy::PATCH_VERSIONS.key?(:unicode_normalize)
  rescue StandardError => e
    flunk "install raised #{e.class}: #{e.message}"
  end

  it "freezes the regexps and the encoding list for workers" do
    %i[REGEXP_D REGEXP_C REGEXP_K UNICODE_ENCODINGS].each do |name|
      value = UnicodeNormalize.const_get(name)
      assert_predicate value, :frozen?, "#{name} must be frozen"
      assert Ractor.shareable?(value), "#{name} must be shareable"
    end
  end

  it "normalizes in main without removing the NF-hash memoization" do
    assert_equal "café", "café".unicode_normalize(:nfc)
    assert_equal "cafe\u0301", "café".unicode_normalize(:nfd)
    assert_equal "1", "①".unicode_normalize(:nfkc)
    assert_equal "café", UnicodeNormalize.normalize("cafe\u0301", :nfc)
  end

  it "normalizes in a worker Ractor on per-Ractor memo hashes" do
    worker = Ractor.new do
      s = "cafe\u0301"
      [s.unicode_normalize(:nfc), UnicodeNormalize.normalize(s, :nfd)]
    end

    assert_equal ["café", "cafe\u0301"], worker.value
  end

  it "answers normalized? in main and in a worker Ractor" do
    assert UnicodeNormalize.normalized?("café", :nfc)
    refute UnicodeNormalize.normalized?("cafe\u0301\u0301", :nfc)
    refute UnicodeNormalize.normalized?("cafe\u0301", :nfc)

    worker = Ractor.new do
      [
        UnicodeNormalize.normalized?("caf\u00e9", :nfc),
        UnicodeNormalize.normalized?("cafe\u0301\u0301", :nfc)
      ]
    end

    assert_equal [true, false], worker.value
  end

  it "keeps NF-memo hashes live on main (upstream mutates them)" do
    # The upstream default-proc memoization must keep working on main: a
    # frozen hash would raise here.
    UnicodeNormalize.normalize("cafe\u0301", :nfc)
    assert_operator UnicodeNormalize::NF_HASH_C.length, :>, 0,
      "NF_HASH_C should memoize on main"
  end

  it "memoizes worker normalizations in the worker's storage" do
    results = Ractor.new do
      normalized = UnicodeNormalize.normalize("cafe\u0301", :nfc)
      memo = RactorRailsShim.storage[:ractor_rails_shim_unicode_nf_c]
      [normalized, memo["e\u0301"], memo.length]
    end

    normalized, _, length = results.value
    assert_equal "café", normalized
    assert_operator length, :>=, 1, "worker should memoize its matches"
  end
end
