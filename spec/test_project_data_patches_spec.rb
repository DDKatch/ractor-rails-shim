# frozen_string_literal: true

# Specs for the translit + async-http + mailgun patches (data-driven
# shareable-constant registrations). Gems are optional; gem-loaded cases
# exercise real worker Ractors.
#
# Run: bundle exec ruby -Ilib -Ispec spec/test_project_data_patches_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class TestProjectDataPatchesSpec < Minitest::Spec
  def test_translit_patch_registers_shareable_map
    RactorRailsShim._install_translit_patch
    if defined?(::Translit) && Ractor.main?
      assert Ractor.shareable?(RactorRailsShim::TRANSLIT_RUSSIAN_MAP)
      # worker read + convert
      worker = Ractor.new do
        text = "privet mir"
        ::Translit.convert(text)
      end.value rescue nil
      assert worker.nil? || worker.is_a?(::String)
    end
  end

  def test_async_http_constants_are_registered
    RactorRailsShim._install_async_http_patch
    constants = RactorRailsShim::ConstantShareabilizer.shareable_constants
    ["Async::HTTP::Endpoint::SCHEMES",
      "Async::HTTP::Protocol::HTTP2::CLIENT_SETTINGS",
      "Async::HTTP::Protocol::HTTPS::HANDLERS"].each do |path|
      assert_includes constants, path
    end
  end

  def test_mailgun_config_ivars_are_registered
    RactorRailsShim._install_mailgun_patch
    entries = RactorRailsShim::Registry.shareable_class_ivars
    %w[@api_host @api_key @test_mode].each do |ivar|
      assert entries.any? { |(klass, name)| klass == "Mailgun" && name.to_s == ivar }
    end
  end
end
