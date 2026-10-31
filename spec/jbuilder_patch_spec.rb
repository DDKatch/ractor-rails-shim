# frozen_string_literal: true

# Specs for the Jbuilder worker-safe patch. Jbuilder is optional (the shim
# bundle doesn't include it); the gem-loaded cases exercise real worker
# Ractors (jbuilder 2.15+ inherits BasicObject, so its DSL relies entirely
# on method_missing -> set! — the patch must keep both main and worker
# encodes working).
#
# Run: bundle exec ruby -Ilib -Ispec spec/jbuilder_patch_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class JbuilderPatchSpec < Minitest::Spec
  def test_install_is_idempotent_and_gem_optional
    first = RactorRailsShim._install_jbuilder_patch
    second = RactorRailsShim._install_jbuilder_patch
    assert first.nil? || first == true
    assert_nil second, "the second install must be a guarded no-op"
  end

  def test_unset_sentinel_is_frozen_and_shareable
    assert RactorRailsShim::UNSET.frozen?
    assert Ractor.shareable?(RactorRailsShim::UNSET)
  end

  def test_worker_jbuilder_key_formatter_is_nil_sans_capture
    assert_nil RactorRailsShim._worker_jbuilder_key_formatter
  end
end

begin
  require "jbuilder"
rescue LoadError
  nil
end

if defined?(::Jbuilder)
  begin
    require "jbuilder/jbuilder_template"
  rescue LoadError
    nil
  end

  class JbuilderPatchGemLoadedSpec < Minitest::Spec
    before do
      RactorRailsShim.instance_variable_set(:@jbuilder_patched, nil)
      RactorRailsShim._install_jbuilder_patch
    end

    it "freezes JbuilderTemplate.template_lookup_options" do
      skip "JbuilderTemplate needs ActionView" unless defined?(::JbuilderTemplate)
      assert Ractor.shareable?(::JbuilderTemplate.template_lookup_options)
    end

    it "captures key_format into a shareable constant" do
      skip unless ::Jbuilder.respond_to?(:key_format)
      ::Jbuilder.key_format(:upcase)
      assert_equal [:upcase], RactorRailsShim::JBUILDER_KEY_FORMATS
    end

    it "encodes in main and in a worker Ractor" do
      skip unless ::Jbuilder.respond_to?(:key_format)
      main = ::Jbuilder.encode { |j| j.first_name("David") }
      worker = Ractor.new do
        j2 = ::Jbuilder.new
        j2.set!(:first_name, "Ada")
        j2.target!
      end.value
      assert main.is_a?(::String) && !main.empty?
      assert worker.is_a?(::String) && !worker.empty?
    end
  end
end
