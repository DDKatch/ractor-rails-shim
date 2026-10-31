# frozen_string_literal: true

# Specs for the smoke-test–derived worker fixes in the rack-attack,
# json-schema, and faraday patches. All three gems are optional (not in the
# shim bundle); the gem-loaded cases replay the real worker-Ractor paths
# that were fixed after the real-gem smoke test flagged them:
#
#   rack-attack: BaseProxy CANNOT read @@proxies off-main even frozen ->
#     frozen RACK_ATTACK_PROXIES snapshot + worker branch in `proxies`;
#     worker `Cache.new` -> `BaseProxy.lookup`; worker `set_defaults`
#     builds real responder lambdas; `Cache.default_store` must use
#     Object.const_get (bare `Rails` does not resolve in eval'd worker code)
#   json-schema: worker `initialize` must not read @@mutex / call helper
#     `_shim_lock`; `use_multi_json?` snapshot; TYPE_CLASS_MAPPINGS and
#     JSON::Util::UUID::Nil frozen; full validate! must run off-main
#   faraday: `Utils` is a module_function module — the memo readers must be
#     redefined on the SINGLETON class; `default_connection_options` gets a
#     worker branch (Faraday.new hits it first and the upstream reader sets
#     a module ivar off-main)
#
# Run under a gemhome containing the gems, WITHOUT bundler:
#   GEM_HOME=... GEM_PATH=... ruby -Ilib -Ispec spec/smoke_worker_fixes_spec.rb

require "minitest/autorun"

# Load the gems FIRST: the shim's loader partially loads ActiveSupport
# (isolated_execution_state, without ActiveSupport::VERSION), which breaks
# rack-attack's `defined?(::ActiveSupport) && ::ActiveSupport::VERSION...`
# probe when it loads afterwards.
begin
  require "rack"
  require "rack/attack"
rescue LoadError
  nil
end

begin
  require "faraday"
rescue LoadError
  nil
end

begin
  require "json-schema"
rescue LoadError
  nil
end

require_relative "../lib/ractor_rails_shim/patches"

if defined?(::Rack::Attack)
  class RackAttackWorkerFixesSpec < Minitest::Spec
    before do
      RactorRailsShim._install_rack_attack_patch
    end

    it "snapshots @@proxies into a frozen RACK_ATTACK_PROXIES constant" do
      snapshot = RactorRailsShim::RACK_ATTACK_PROXIES

      assert_predicate snapshot, :frozen?
      assert Ractor.shareable?(snapshot), "the proxy snapshot must be shareable"
      assert_equal ::Rack::Attack::BaseProxy.proxies, snapshot.to_a
      # Main's own registry stays mutable so late proxies still register.
      refute_predicate ::Rack::Attack::BaseProxy.class_variable_get(:@@proxies), :frozen?,
        "main @@proxies must stay mutable"
    end

    it "resolves proxy lookups in a worker via the snapshot" do
      result = Ractor.new do
        cache = ::Rack::Attack::Cache.new(store: Object.new)
        [
          cache.store.class.name,
          ::Rack::Attack::BaseProxy.lookup(nil).nil?
        ]
      end

      assert_equal ["Object", true], result.value
    end

    it "builds real default responders in a worker's Configuration" do
      result = Ractor.new do
        config = ::Rack::Attack::Configuration.new
        block = config.blocklisted_responder
        request = ::Rack::Attack::Request.new({})
        blocked = block.call(request)
        throttled = config.throttled_responder.call(
          ::Rack::Attack::Request.new(
            "rack.attack.match_data" => {epoch_time: 1_700_000_000, period: 60}
          )
        )
        [blocked[0], throttled[0], throttled[1]["content-type"]]
      end

      assert_equal [403, 429, "text/plain"], result.value
    end

    it "honors throttled_response_retry_after_header in a worker" do
      result = Ractor.new do
        # The responder lambda re-queries ::Rack::Attack.configuration at
        # call time, so the flag lives on the shared per-Ractor
        # configuration object, not the local instance.
        config = ::Rack::Attack.configuration
        config.throttled_response_retry_after_header = true
        request = ::Rack::Attack::Request.new(
          "rack.attack.match_data" => {epoch_time: 1_700_000_030, period: 60}
        )
        response = ::Rack::Attack::Configuration.new.throttled_responder.call(request)
        [response[0], response[1]["retry-after"]]
      end

      assert_equal [429, "10"], result.value
    end

    it "keeps Cache.default_store worker-safe via Object.const_get" do
      # Without Rails loaded the default store simply stays nil, but the
      # lookup path (the part the smoke crashed on) must still work off-main.
      result = Ractor.new { ::Rack::Attack::Cache.new(store: Object.new).store.class.name }
      assert_equal "Object", result.value
    end
  end
end

if defined?(::JSON::Validator)
  class JsonSchemaWorkerFixesSpec < Minitest::Spec
    before do
      # Worker validate! reads schema keys through JSON::Util::URI ->
      # Addressable -> String#unicode_normalize (the stdlib stack), so the
      # unicode_normalize patch must be installed too.
      RactorRailsShim._install_unicode_normalize_patch
      RactorRailsShim._install_json_schema_patch
    end

    it "freezes TYPE_CLASS_MAPPINGS for the validation path" do
      mappings = JSON::Schema::Attribute::TYPE_CLASS_MAPPINGS

      assert_predicate mappings, :frozen?
      assert Ractor.shareable?(mappings)
    end

    it "freezes the RFC4122 Nil UUID namespace for fake_uuid" do
      assert_predicate JSON::Util::UUID::Nil, :frozen?
      assert Ractor.shareable?(JSON::Util::UUID::Nil), "Nil UUID must be shareable"
    end

    it "resolves use_multi_json? in a worker without reading @@use_multi_json" do
      result = Ractor.new { ::JSON::Validator.use_multi_json? }
      assert_equal(::Object.const_defined?(:MultiJson), result.value)
    end

    it "runs validate! fully in a worker Ractor" do
      result = Ractor.new do
        schema = {
          "type" => "object",
          "properties" => {"name" => {"type" => "string"}}
        }
        ::JSON::Validator.validate!(schema, {"name" => "ok"})
        begin
          ::JSON::Validator.validate!(schema, {"name" => 42})
        rescue ::JSON::Schema::ValidationError
          :raised
        end
      end

      assert_equal :raised, result.value, "valid data must pass, bad data must raise in the worker"
    end
  end
end

if defined?(::Faraday)
  class FaradayWorkerFixesSpec < Minitest::Spec
    before do
      RactorRailsShim._install_faraday_patch
    end

    it "patches the module_function singleton copies of the Utils memos" do
      location = ::Faraday::Utils.method(:default_uri_parser).source_location

      refute_nil location
      assert location[0].end_with?("faraday.rb"),
        "default_uri_parser must be redefined by the patch (got #{location.join(":")})"
    end

    it "memoizes default_connection_options per Ractor" do
      result = Ractor.new do
        first = ::Faraday.default_connection_options
        second = ::Faraday.default_connection_options
        [first.class.name, first.equal?(second)]
      end

      assert_equal ["Faraday::ConnectionOptions", true], result.value
    end

    it "builds a Connection in a worker via Faraday.new (default stack)" do
      # No block: the default rack-builder stack must resolve
      # `request :url_encoded` off-main via the Request/Response registry
      # snapshot.
      result = Ractor.new do
        conn = ::Faraday.new(url: "http://example.invalid")
        [conn.url_prefix.host, conn.builder.handlers.first.klass.name]
      end

      assert_equal ["example.invalid", "Faraday::Request::UrlEncoded"], result.value
    end

    it "registers Request/Response registries in the snapshot" do
      keys = RactorRailsShim::FARADAY_MW_REGISTRIES.keys

      assert_includes keys, "Faraday::Request"
      assert_includes keys, "Faraday::Response"
    end

    it "still memoizes default_connection_options lazily on main" do
      first = ::Faraday.default_connection_options

      assert_equal first, ::Faraday.default_connection_options
      assert first.equal?(::Faraday.default_connection_options),
        "main must keep the upstream lazy memoization"
    end
  end
end
