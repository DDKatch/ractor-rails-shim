# frozen_string_literal: true

# Specs for the remaining test-project patch installs (prawn, telegram-bot,
# feelings, simple_form, json-schema, faraday, rack-attack, ruby_llm,
# fast_jsonapi, sprockets-rails): every install must be gem-optional
# (no raise when the gem isn't loaded), idempotent, and registered in the
# version policy.
#
# Run: bundle exec ruby -Ilib -Ispec spec/test_project_install_spec.rb

require "minitest/autorun"
require_relative "../lib/ractor_rails_shim/patches"

class TestProjectInstallSpec < Minitest::Spec
  PATCH_INSTALLS = {
    prawn: :_install_prawn_patch,
    telegram_bot: :_install_telegram_bot_patch,
    feelings: :_install_feelings_patch,
    simple_form: :_install_simple_form_patch,
    json_schema: :_install_json_schema_patch,
    faraday: :_install_faraday_patch,
    rack_attack: :_install_rack_attack_patch,
    ruby_llm: :_install_ruby_llm_patch,
    fast_jsonapi: :_install_fast_jsonapi_patch,
    sprockets_rails: :_install_sprockets_rails_patch
  }.freeze

  it "installs safely without the gem and is idempotent" do
    PATCH_INSTALLS.each do |name, install|
      first = RactorRailsShim.public_send(install)
      second = RactorRailsShim.public_send(install)
      assert first.nil? || first == true, "#{name}: first install returned #{first.inspect}"
      assert_nil second, "#{name}: second install must be a guarded no-op"
      assert RactorRailsShim::VersionPolicy::PATCH_VERSIONS.key?(name),
        "#{name}: patch should be registered in the version policy"
    rescue StandardError => e
      flunk "#{name}: install raised #{e.class}: #{e.message}"
    end
  end

  it "registers shareable class ivars for prawn's registries" do
    RactorRailsShim._install_prawn_patch
    entries = RactorRailsShim::Registry.shareable_class_ivars
    assert entries.any? { |(k, ivar)| k == "Prawn" && ivar == :@image_handler }
    assert entries.any? { |(k, ivar)| k == "Prawn::Document" && ivar == :@extensions }
  end

  it "resolves faraday header keys identically to the upstream KeyMap" do
    assert_equal "User-Agent", RactorRailsShim._faraday_header_key(:user_agent)
    assert_equal "ETag", RactorRailsShim._faraday_header_key(:etag)
    assert_equal "Etag", RactorRailsShim._faraday_header_key("Etag"),
      "string keys pass through (respond_to?(:to_str))"
    assert_equal "Accept-Language", RactorRailsShim._faraday_header_key(:accept_language)
  end

  it "freezes the sprockets manifest snapshot cleanly" do
    snapshot = RactorRailsShim::SprocketsManifestSnapshot.new({"a.css" => "a-hash.css"}, {"a-hash.css" => {}})
    assert Ractor.shareable?(snapshot)
    assert_equal "a-hash.css", snapshot.assets["a.css"]
    assert_equal({}, snapshot.files["a-hash.css"])
  end
end
