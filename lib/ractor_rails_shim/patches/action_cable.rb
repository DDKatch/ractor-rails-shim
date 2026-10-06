# frozen_string_literal: true

# Action Cable worker broadcast support (Solid Cable adapter).
#
# `ActionCable.server` (action_cable.rb, module_function) lazily memoizes the
# module ivar `@server`. make_app_shareable! deep-freezes the ActionCable
# module graph, so in a worker Ractor the memoized server is a FROZEN
# ActionCable::Server::Base. A worker calling `ActionCable.server.broadcast`
# hits `Server::Base#pubsub` (`@pubsub ||=`) → FrozenError: "can't modify
# frozen ActionCable::Server::Base" (observed for a Solid Cable broadcast
# from a kino worker via /cable_probe).
#
# Fix, mirroring the per-Ractor ActiveRecord connection handler pattern
# (init_worker_ar_connections!):
#   - Main, at prepare_for_ractors! time: snapshot `server.config.cable` (the
#     config/cable.yml env hash — plain scalars) into the shareable constant
#     CABLE_CONFIG_SHAREABLE, and re-define the `server` module function with
#     a main/worker branch. The re-definition is a real `def` (no Proc), so
#     it survives the deep-freeze and every worker clone carries it.
#   - Worker, lazily on first `ActionCable.server` call: build a FRESH
#     per-Ractor Server::Base with a fresh Configuration whose `cable` is the
#     shareable snapshot and whose `logger` is the worker's ActiveRecord
#     logger, memoized in Ractor.current (per-Ractor, shared by all the
#     worker's threads — same rationale as the connection handler).
#
# The broadcast path then works entirely in the worker:
#   Server::Base#pubsub → config.pubsub_adapter (reads the frozen snapshot
#   hash, requires the adapter file from disk, constantizes the class — all
#   Ractor-safe) → SolidCable adapter (@server.mutex is the fresh server's
#   Monitor) → SolidCable::BatchedBroadcaster (its background writer thread
#   + FixedThreadPool are created in the worker; Thread.new is allowed in
#   non-main Ractors) → SolidCable::Message.broadcast_batch → a plain
#   ActiveRecord insert through the worker's default connection pool.
# Delivery to WebSocket clients remains the main-Ractor cable server's
# poller concern (out of scope for workers).

module RactorRailsShim
  # Deep-frozen copy of `ActionCable.server.config.cable` (the resolved
  # config/cable.yml hash for the current env), captured in the main Ractor
  # at prepare time. Workers build their per-Ractor cable server
  # Configuration from it. nil if Action Cable is not configured.
  CABLE_CONFIG_SHAREABLE = nil

  # Deep-frozen copy of the Solid Cable configuration options hash (the
  # `SolidCable.configuration` kwargs source), captured in the main Ractor
  # at prepare time. Workers build a per-Ractor SolidCable::Configuration
  # from it. nil if Solid Cable is not loaded.
  SOLID_CABLE_OPTIONS_SHAREABLE = nil

  class << self
    def _install_action_cable_worker_server_patch!
      return if @action_cable_server_patched
      @action_cable_server_patched = true
      _register_patch :action_cable_worker_server, "8.1"
      return unless defined?(::ActionCable::Server::Base)
      return unless defined?(::Ractor)
      return unless ::ActionCable.respond_to?(:server)

      # Snapshot the resolved cable config (adapter name + adapter options)
      # into a shareable constant. Done BEFORE the deep-freeze so the snapshot
      # exists when workers build their Configuration.
      if ::ActionCable.server.config.respond_to?(:cable)
        cable = ::ActionCable.server.config.cable
        if cable.is_a?(Hash) && !cable.empty?
          shareable = Ractor.make_shareable(cable.dup)
          _reassign_shareable_const(:CABLE_CONFIG_SHAREABLE, shareable)
        end
      end

      # Re-define the module function `ActionCable.server` with a
      # main/worker branch. Real `def` bodies (no Proc) — workers inherit
      # the re-definition through the (cloned or shared frozen) module.
      ::ActionCable.singleton_class.class_eval <<~'RUBY', __FILE__, __LINE__ + 1
        remove_method :server rescue nil

        def server
          if ::Ractor.main? || !::RactorRailsShim.respond_to?(:build_worker_cable_server!, true)
            @server ||= ::ActionCable::Server::Base.new
          else
            ::RactorRailsShim.build_worker_cable_server!
          end
        end
      RUBY
    rescue StandardError => e
      warn "ractor-rails-shim: Action Cable worker server patch failed " \
           "(#{e.class}: #{e.message[0, 200]})"
      nil
    end

    # Build (once per worker Ractor) a fresh, unfrozen ActionCable server.
    # The Configuration is fresh (its defaults are plain values, built in
    # this Ractor); only `cable` comes from the shareable main snapshot and
    # `logger` from the worker's own ActiveRecord logger. Memoized in
    # Ractor.current so every thread of the worker shares one server (same
    # rationale as the per-Ractor connection handler).
    def build_worker_cable_server!
      existing = Ractor.current[:rrs_cable_server]
      return existing if existing

      cfg = ::ActionCable::Server::Configuration.new
      cfg.cable = CABLE_CONFIG_SHAREABLE if CABLE_CONFIG_SHAREABLE
      begin
        cfg.logger = ::ActiveRecord::Base.logger if defined?(::ActiveRecord::Base)
      rescue StandardError
        # No worker logger available — the broadcast path does not need one.
      end

      server = ::ActionCable::Server::Base.new(config: cfg)
      Ractor.current[:rrs_cable_server] = server
    end

    # SolidCable.configuration memoizes a Configuration object in the module
    # ivar `@configuration` (lib/solid_cable.rb). In a worker the ivar READ
    # raises IsolationError (the object is unshareable), and the `||=` WRITE
    # would too; `BatchedBroadcaster#initialize` hits it via
    # `SolidCable.writer_batch_size`. Re-define the singleton reader with a
    # main/worker branch: main keeps the original lazy semantics; workers
    # build a FRESH per-Ractor Configuration from the shareable options
    # snapshot (memoized in Ractor.current). Configuration's lazy attrs
    # (parse_duration etc.) are pure Ruby and safe in a worker.
    def _install_solid_cable_configuration_patch!
      return if @solid_cable_configuration_patched
      @solid_cable_configuration_patched = true
      _register_patch :solid_cable_configuration, "8.1"
      return unless defined?(::SolidCable::Configuration)
      return unless defined?(::Ractor)
      return unless ::SolidCable.respond_to?(:configuration)

      if ::SolidCable.configuration.respond_to?(:options, true)
        options = (::SolidCable.configuration.send(:options).to_h rescue nil)
        if options.is_a?(Hash) && !options.empty?
          shareable = Ractor.make_shareable(options)
          _reassign_shareable_const(:SOLID_CABLE_OPTIONS_SHAREABLE, shareable)
        end
      end

      ::SolidCable.singleton_class.class_eval <<~'RUBY', __FILE__, __LINE__ + 1
        def configuration
          if ::Ractor.main?
            @configuration ||= ::SolidCable::Configuration.new(**::Rails.application.config_for("cable"))
          else
            ::RactorRailsShim.build_worker_solid_cable_configuration!
          end
        end
      RUBY
    rescue StandardError => e
      warn "ractor-rails-shim: Solid Cable configuration patch failed " \
           "(#{e.class}: #{e.message[0, 200]})"
      nil
    end

    # Per-Ractor SolidCable::Configuration for workers, built from the
    # shareable options snapshot captured in main (nil snapshot → nil, which
    # callers treat the same as an absent configuration).
    def build_worker_solid_cable_configuration!
      existing = Ractor.current[:rrs_solid_cable_configuration]
      return existing if existing

      return nil unless SOLID_CABLE_OPTIONS_SHAREABLE

      cfg = ::SolidCable::Configuration.new(**SOLID_CABLE_OPTIONS_SHAREABLE)
      Ractor.current[:rrs_solid_cable_configuration] = cfg
    end
  end
end
