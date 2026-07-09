# frozen_string_literal: true

# Patch ActiveRecord's connection handler to work in per-Ractor mode.
#
# Blocker 1 (from NEXT_STEPS.md):
#   ActiveRecord::Base.connection_pool calls
#   default_connection_handler.retrieve_connection_pool(...)
#   at connection_handling.rb:346. The default_connection_handler
#   class_attribute is known-unshareable (holds callback chains with
#   self-capturing Procs), so the shim's nil fallback is correct for
#   callbacks BUT AR needs a live connection pool per worker. DB connections
#   can't cross Ractor boundaries.
#
# Fix: Each worker Ractor gets its own ConnectionHandler with its own pool,
# seeded from the same db config as main. We patch `connection_handler` /
#   `connection_handler=` / `default_connection_handler` to use per-Ractor
#   storage (IES), and provide a worker-init hook that creates a new
#   ConnectionHandler + establishes a connection from the same pool spec.
#
# Rails already uses IES for `connection_handler` (core.rb:132-138):
#   def self.connection_handler
#     ActiveSupport::IsolatedExecutionState[:active_record_connection_handler] || default_connection_handler
#   end
#   def self.connection_handler=(handler)
#     ActiveSupport::IsolatedExecutionState[:active_record_connection_handler] = handler
#   end
#
# The problem: in the main ractor, `default_connection_handler` is set via
# class_attribute (core.rb:97+248). In a worker ractor, the shim's
# class_attribute patch returns nil for default_connection_handler (it's
# in the known-unshareable skip list). So connection_handler returns nil,
# and `connection_pool` raises NoMethodError on nil.
#
# The fix: in each worker, call RactorRailsShim.init_worker_ar_connections!
# which creates a fresh ConnectionHandler and establishes connections from
# the same configurations as main. The handler is stored in IES (which
# Rails already reads). We also capture the pool spec (db configs) in the
# main ractor at prepare_for_ractors! time as a shareable constant so workers
# can read it.

module RactorRailsShim
  # Shareable snapshot of ActiveRecord::Base.configurations at
  # prepare_for_ractors! time. Workers read this to establish their own
  # connection pools with the same db config. Made shareable (frozen).
  AR_CONFIGURATIONS_SNAPSHOT = nil

  class << self
    # Capture the db configurations from the main ractor at
    # prepare_for_ractors! / make_app_shareable! time. This is a shareable
    # snapshot (frozen Hash of config hashes) that workers use to establish
    # their own connection pools. Must run in the main Ractor.
    def _capture_ar_configurations!
      return if @_ar_configs_captured
      @_ar_configs_captured = true
      return unless defined?(::ActiveRecord::Base)

      begin
        configs = ::ActiveRecord::Base.configurations
        snapshot = {}
        configs.each do |db_config|
          snapshot[db_config.env_name] ||= {}
          snapshot[db_config.env_name][db_config.name] = {
            "adapter" => db_config.adapter,
            "database" => db_config.database,
            "host" => db_config.host,
            "port" => db_config.port,
            "username" => db_config.username,
            "password" => db_config.password,
            "pool" => db_config.configuration_hash[:pool] || 5,
            "timeout" => db_config.configuration_hash[:timeout],
            "encoding" => db_config.configuration_hash[:encoding],
            "collation" => db_config.configuration_hash[:collation],
          }.compact
        end
        snapshot.freeze
        Ractor.make_shareable(snapshot)
        verbose, $VERBOSE = $VERBOSE, nil
        begin
          const_set(:AR_CONFIGURATIONS_SNAPSHOT, snapshot)
        ensure
          $VERBOSE = verbose
        end
      rescue => e
        # Best-effort; if we can't capture configs, workers won't be able
        # to auto-init connections. They can call init_worker_ar_connections!
        # manually with explicit configs.
      end
    end

    # Worker-Ractor hook: create a fresh ConnectionHandler and establish
    # connections from the captured configurations snapshot. Call this in
    # each worker Ractor before serving requests:
    #
    #   Ractor.new(app) do |a|
    #     RactorRailsShim.init_worker_ar_connections!
    #     a.call(env)
    #   end
    #
    # Idempotent: safe to call multiple times (subsequent calls are no-ops
    # once the handler is established). Uses Ractor.store_if_absent semantics
    # via IES.
    def init_worker_ar_connections!
      return if Ractor.main?
      return unless defined?(::ActiveRecord::Base)

      key = :active_record_connection_handler
      existing = ActiveSupport::IsolatedExecutionState[key]
      return if existing

      handler = ::ActiveRecord::ConnectionAdapters::ConnectionHandler.new

      # Establish connections from the captured configurations snapshot.
      snapshot = AR_CONFIGURATIONS_SNAPSHOT
      if snapshot && !snapshot.empty?
        env = ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence || "development"
        env_configs = snapshot[env] || snapshot.values.first || {}

        env_configs.each do |name, config|
          begin
            # Build a db_config from the snapshot hash and establish.
            # Use establish_connection with the config hash directly —
            # AR resolves it through DatabaseConfigurations.
            handler.establish_connection(config, owner_name: ::ActiveRecord::Base, role: ::ActiveRecord::Base.current_role, shard: ::ActiveRecord::Base.current_shard)
          rescue => e
            # Best-effort: if one connection fails, continue with others.
            # The worker will raise a clear error on the first DB-touching
            # request if no connection was established.
          end
        end
      end

      ActiveSupport::IsolatedExecutionState[key] = handler
    end

    # Patch ActiveRecord::Base to route default_connection_handler through
    # IES, and ensure connection_handler returns the per-Ractor handler.
    # In the main ractor, falls back to the original default_connection_handler
    # (set at core.rb:248). In workers, falls back to nil (correct — workers
    # must call init_worker_ar_connections! to establish their own handler).
    # Also patches retrieve_connection / connected? / connection_pool to
    # tolerate nil handler (raise a clear error message instead of
    # NoMethodError on nil).
    def _install_activerecord_connection_handler_patch
      return if @ar_conn_handler_patched
      @ar_conn_handler_patched = true
      _register_patch :activerecord_connection_handler, "8.1"
      return unless defined?(::ActiveRecord::ConnectionHandling)

      # Capture configs at install time if AR is already loaded (main ractor).
      _capture_ar_configurations! if Ractor.main?

      # Patch default_connection_handler to route through IES.
      # The class_attribute reader for default_connection_handler is already
      # patched by the shim (it's in the known-unshareable skip list → nil
      # in workers). We override the class method to return the per-Ractor
      # handler if set, then fall back to the original (main only) or nil.
      dch_key = :ractor_rails_shim_ar_default_connection_handler
      dch_key_str = dch_key.inspect
      ::ActiveRecord::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_connection_handler
          v = ActiveSupport::IsolatedExecutionState[#{dch_key_str}]
          return v unless v.nil?
          if Ractor.main?
            # In main, read the original class_attribute value (set at boot
            # via self.default_connection_handler = ConnectionHandler.new).
            # The class_attribute reader returns this via the shim's
            # CLASS_ATTR_VALUES fallback.
            cv = RactorRailsShim::CLASS_ATTR_VALUES[:__ractor_rails_shim_ar_default_connection_handler__]
            return cv if cv
            # Fall back to the instance variable if class_attribute set it.
            if instance_variable_defined?(:@default_connection_handler)
              return instance_variable_get(:@default_connection_handler)
            end
          end
          nil
        end
        def default_connection_handler=(val)
          ActiveSupport::IsolatedExecutionState[#{dch_key_str}] = val
        end
      RUBY

      # Also ensure connection_handler (which Rails already routes through IES
      # at core.rb:132-138) works. Rails' implementation:
      #   def self.connection_handler
      #     ActiveSupport::IsolatedExecutionState[:active_record_connection_handler] || default_connection_handler
      #   end
      # This is already correct — if the worker sets the IES key via
      # init_worker_ar_connections!, connection_handler returns it. If not,
      # it falls back to default_connection_handler (nil in workers).
      #
      # We just need to make sure connection_pool / retrieve_connection
      # give a clear error message when the handler is nil (instead of
      # NoMethodError: undefined method `retrieve_connection_pool' for nil).
      ::ActiveRecord::ConnectionHandling.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def connection_pool
          handler = connection_handler
          unless handler
            raise ActiveRecord::ConnectionNotEstablished,
              "No connection handler for Ractor \#{Ractor.current.object_id}. " \
              "Call RactorRailsShim.init_worker_ar_connections! in each worker " \
              "Ractor before serving requests."
          end
          handler.retrieve_connection_pool(connection_specification_name, role: current_role, shard: current_shard, strict: true)
        end
        def retrieve_connection
          handler = connection_handler
          unless handler
            raise ActiveRecord::ConnectionNotEstablished,
              "No connection handler for Ractor \#{Ractor.current.object_id}. " \
              "Call RactorRailsShim.init_worker_ar_connections! in each worker " \
              "Ractor before serving requests."
          end
          handler.retrieve_connection(connection_specification_name, role: current_role, shard: current_shard)
        end
        def connected?
          handler = connection_handler
          return false unless handler
          handler.connected?(connection_specification_name, role: current_role, shard: current_shard)
        end
      RUBY

      # Capture the main ractor's default_connection_handler value into
      # CLASS_ATTR_VALUES so the patched reader can find it. The key must
      # match the one used in the class_attribute redefine.
      if Ractor.main?
        begin
          orig_handler = ::ActiveRecord::Base.instance_variable_get(:@default_connection_handler) rescue nil
          if orig_handler
            RactorRailsShim::CLASS_ATTR_VALUES[:__ractor_rails_shim_ar_default_connection_handler__] = orig_handler
            # Also seed IES in main so connection_handler finds it immediately.
            ActiveSupport::IsolatedExecutionState[dch_key] = orig_handler
          end
        rescue => e
          # Best-effort
        end
      end
    end
  end
end
