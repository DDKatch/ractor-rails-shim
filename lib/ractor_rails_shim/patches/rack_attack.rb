# frozen_string_literal: true

# Patch Rack::Attack (6.x) for worker Ractors.
#
# Everything Rack::Attack consults per request lives on the MODULE
# (`lib/rack/attack.rb:90-101`): `@configuration` (Configuration holding the
# DSL-built Safelist/Blocklist/Throttle/Track objects with user check
# blocks), `@cache` (the `||=`-memoized Cache), the
# `@throttle_discriminator_normalizer` lambda, plus the
# `@@proxies` class-variable registry read when a Cache store is wrapped
# (`cache.rb:24 BaseProxy.lookup`). The middleware INSTANCE (frozen in the
# shared app graph) also carries `@configuration` copied from the module at
# construction — a worker reading it raises IsolationError before the DSL
# even runs.
#
# Worker semantics: the COUNTERS live in the external store (Rails.cache /
# Redis), NOT in these objects — so per-Ractor Configuration/Cache objects
# are safe and correct as long as they wrap the same external store.
#
#   * `Rack::Attack.cache` — main keeps its memo; each worker memoizes its
#     own `Cache.new` (default store = the same `Rails.cache`) via storage.
#   * `Rack::Attack.throttle_discriminator_normalizer` — main keeps the
#     boot lambda; workers build the equivalent fresh lambda via storage.
#   * `@@proxies` — snapshotted at install into the frozen
#     `RactorRailsShim::RACK_ATTACK_PROXIES` constant; workers read the
#     snapshot. Class variables are unreadable off-main even when the value
#     is shareable, so freezing `@@proxies` in place is not enough. Store
#     proxies defined after install are not in the snapshot.
#   * `Rack::Attack#call` — redefined with a worker branch that resolves the
#     configuration through the module accessor (per-Ractor in workers)
#     instead of the frozen middleware instance's ivar.
#   * `Rack::Attack.configuration` (the reader) — main returns the module
#     ivar; workers memoize a fresh DEFAULT `Configuration` via storage.
#
# KNOWN LIMITATION (documented in COMPATIBILITY.md): the DSL check blocks
# (throttle/blocklist/safelist/track) are user Procs defined in the main
# Ractor and CANNOT cross the Ractor boundary. Workers therefore run with a
# default (DSL-less) configuration by default. To arm the DSL per worker,
# register re-arm blocks with `::RactorRailsShim.on_worker_boot { ... }` —
# blocks created inside the worker are worker-local and callable; the DSL
# call shape is identical (`Rack::Attack.throttle(...)`).

module RactorRailsShim
  class << self
    def _install_rack_attack_patch
      return if @rack_attack_patched
      @rack_attack_patched = true
      _register_patch :rack_attack, "8.1"
      return unless defined?(::Rack::Attack)

      _snapshot_rack_attack_proxies
      _install_rack_attack_base_proxy
      _install_rack_attack_module_accessors
      _install_rack_attack_call
      _install_rack_attack_worker_safe_defaults
      _install_rack_attack_cache_default_store
    end

    private

    # Snapshot `@@proxies` into the frozen `RACK_ATTACK_PROXIES` constant
    # (an Array of proxy Classes is shareable). `@@proxies` itself is left
    # untouched on main so late-registered proxies still register there.
    def _snapshot_rack_attack_proxies
      return unless ::Ractor.main? && defined?(::Rack::Attack::BaseProxy)
      proxies = ::Rack::Attack::BaseProxy.class_variable_get(:@@proxies) rescue nil
      proxies = [] unless proxies.is_a?(::Array)
      _reassign_shareable_const(:RACK_ATTACK_PROXIES, ::Ractor.make_shareable(proxies.dup))
    rescue ::StandardError
      nil
    end

    # `@@proxies` is a class variable — unreadable off-main even when its
    # value is shareable — so `proxies` gets a worker branch reading the
    # frozen snapshot. `inherited` and `lookup` are kept verbatim:
    # `inherited` only fires on main and `lookup` delegates to `proxies`.
    def _install_rack_attack_base_proxy
      return unless defined?(::Rack::Attack::BaseProxy)
      ::Rack::Attack::BaseProxy.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        class << self
          def proxies
            if ::Ractor.main?
              @@proxies ||= []
            else
              ::RactorRailsShim::RACK_ATTACK_PROXIES
            end
          end
        end
      RUBY
    end

    def _install_rack_attack_module_accessors
      ::Rack::Attack.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def cache
          if ::Ractor.main?
            @cache ||= Cache.new
          else
            key = :ractor_rails_shim_rack_attack_cache
            ::RactorRailsShim.storage[key] ||= ::Rack::Attack::Cache.new
            ::RactorRailsShim.storage[key]
          end
        end
        def configuration
          if ::Ractor.main?
            instance_variable_get(:@configuration) ||
              (instance_variable_set(:@configuration, Configuration.new))
          else
            key = :ractor_rails_shim_rack_attack_configuration
            ::RactorRailsShim.storage[key] ||= ::Rack::Attack::Configuration.new
            ::RactorRailsShim.storage[key]
          end
        end

        def throttle_discriminator_normalizer
          if ::Ractor.main?
            @throttle_discriminator_normalizer ||= lambda do |discriminator|
              discriminator.to_s.strip.downcase
            end
          else
            key = :ractor_rails_shim_rack_attack_normalizer
            ::RactorRailsShim.storage[key] ||= lambda do |discriminator|
              discriminator.to_s.strip.downcase
            end
            ::RactorRailsShim.storage[key]
          end
        end
      RUBY
    end

    def _install_rack_attack_call
      ::Rack::Attack.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def call(env)
          return @app.call(env) if !self.class.enabled || env["rack.attack.called"]

          env["rack.attack.called"] = true
          env['PATH_INFO'] = ::Rack::Attack::PathNormalizer.normalize_path(env['PATH_INFO'])
          request = ::Rack::Attack::Request.new(env)
          configuration = self.class.configuration

          if configuration.safelisted?(request)
            @app.call(env)
          elsif configuration.blocklisted?(request)
            # Deprecated: Keeping blocklisted_response for backwards compatibility
            if configuration.blocklisted_response
              configuration.blocklisted_response.call(env)
            else
              configuration.blocklisted_responder.call(request)
            end
          elsif configuration.throttled?(request)
            # Deprecated: Keeping throttled_response for backwards compatibility
            if configuration.throttled_response
              configuration.throttled_response.call(env)
            else
              configuration.throttled_responder.call(request)
            end
          else
            configuration.tracked?(request)
            @app.call(env)
          end
        end
      RUBY
    end

    # Worker branch for Configuration#set_defaults: the captured
    # `DEFAULT_*_RESPONDER` constants hold main-Ractor lambdas (Proc in a
    # constant — unreadable off-main). The worker branch builds equivalent
    # fresh lambdas Ractor-locally instead of reading the constants.
    # Main keeps the original statements verbatim.
    def _install_rack_attack_worker_safe_defaults
      return unless defined?(::Rack::Attack::Configuration)
      ::Rack::Attack::Configuration.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def set_defaults
          if ::Ractor.main?
            @safelists = {}
            @blocklists = {}
            @throttles = {}
            @tracks = {}
            @anonymous_blocklists = []
            @anonymous_safelists = []
            @throttled_response_retry_after_header = false

            @blocklisted_responder = DEFAULT_BLOCKLISTED_RESPONDER
            @throttled_responder = DEFAULT_THROTTLED_RESPONDER

            # Deprecated: Keeping these for backwards compatibility
            @blocklisted_response = nil
            @throttled_response = nil
          else
            @safelists = {}
            @blocklists = {}
            @throttles = {}
            @tracks = {}
            @anonymous_blocklists = []
            @anonymous_safelists = []
            @throttled_response_retry_after_header = false

            @blocklisted_responder = lambda do |_req|
              [403, { 'content-type' => 'text/plain' }, ["Forbidden\n"]]
            end
            @throttled_responder = lambda do |req|
              if ::Rack::Attack.configuration.throttled_response_retry_after_header
                match_data = req.env['rack.attack.match_data']
                now = match_data[:epoch_time]
                retry_after = match_data[:period] - (now % match_data[:period])

                [429, { 'content-type' => 'text/plain', 'retry-after' => retry_after.to_s }, ["Retry later\n"]]
              else
                [429, { 'content-type' => 'text/plain' }, ["Retry later\n"]]
              end
            end
            @blocklisted_response = nil
            @throttled_response = nil
          end
        end
      RUBY
    end

    # Worker branch for `Cache.default_store`: the original reads the bare
    # `Rails` constant, which does not resolve in string-eval'd code running
    # in a worker. `::Object.const_get` works off-main.
    def _install_rack_attack_cache_default_store
      return unless defined?(::Rack::Attack::Cache)
      ::Rack::Attack::Cache.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def self.default_store
          if ::Object.const_defined?(:Rails) && ::Object.const_get(:Rails).respond_to?(:cache)
            ::Object.const_get(:Rails).cache
          end
        end
      RUBY
    end
  end
end
