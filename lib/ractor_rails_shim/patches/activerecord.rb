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
  # ActiveRecord holds several mutable container constants (Arrays / Sets of
  # symbols) that are read during query execution (unscope, order, etc.).
  # Reading them from a worker Ractor raises Ractor::IsolationError
  # ("can not access non-shareable objects in constant ..."). Register them so
  # the shim deep-freezes + const_set's a shareable twin at prepare time.
  SHAREABLE_CONSTANTS.concat([
    "ActiveRecord::QueryMethods::VALID_UNSCOPING_VALUES",
    "ActiveRecord::QueryMethods::VALID_DIRECTIONS",
    "ActiveRecord::Relation::MULTI_VALUE_METHODS",
    "ActiveRecord::Relation::SINGLE_VALUE_METHODS",
    "ActiveRecord::Relation::VALUE_METHODS",
    "ActiveRecord::Relation::CLAUSE_METHODS",
    "ActiveRecord::Relation::INVALID_METHODS_FOR_UPDATE_AND_DELETE_ALL",
    "ActiveRecord::Relation::Merger::NORMAL_VALUES",
    "ActiveRecord::Relation::WhereClause::ARRAY_WITH_EMPTY_STRING",
    "ActiveRecord::AttributeMethods::RESTRICTED_CLASS_METHODS",
    "ActiveRecord::AttributeMethods::PrimaryKey::ClassMethods::ID_ATTRIBUTE_METHODS",
    "ActiveRecord::Callbacks::CALLBACKS",
    "ActiveRecord::ConnectionAdapters::ColumnDefinition::OPTION_NAMES",
    "ActiveRecord::ConnectionAdapters::SQLite3Adapter::DEFAULT_PRAGMAS",
    "ActiveRecord::ConnectionAdapters::SQLite3Adapter::NATIVE_DATABASE_TYPES",
    "ActiveRecord::ConnectionHandling::DEFAULT_ENV",
    "ActiveRecord::ConnectionHandling::RAILS_ENV",
    "ActiveRecord::NestedAttributes::UNASSIGNABLE_KEYS",
    "ActiveRecord::Transactions::ACTIONS",
    "ActiveRecord::LogSubscriber::IGNORE_PAYLOAD_NAMES",
    "ActiveRecord::ExplainRegistry::Subscriber::IGNORED_PAYLOADS",
    "ActiveRecord::StructuredEventSubscriber::IGNORE_PAYLOAD_NAMES",
    "ActiveRecord::Encryption::Context::PROPERTIES",
    "ActiveRecord::Encryption::Encryptor::DECRYPT_ERRORS",
    "ActiveRecord::Encryption::Encryptor::ENCODING_ERRORS",
    "ActiveRecord::Encryption::Properties::ALLOWED_VALUE_CLASSES",
    "ActiveRecord::Encryption::Properties::DEFAULT_PROPERTIES",
    "Arel::SelectManager::STRING_OR_SYMBOL_CLASS",
  ])

  # Shareable snapshot of ActiveRecord::Base.configurations at
  # prepare_for_ractors! time. Workers read this to establish their own
  # connection pools with the same db config. Made shareable (frozen).
  AR_CONFIGURATIONS_SNAPSHOT = nil

  # Shareable (deep-frozen) copy of ActiveRecord::Base.configurations (the
  # DatabaseConfigurations object) captured at prepare time. Workers read
  # this instead of the raw `@@configurations` class variable, which a
  # non-main Ractor cannot access.
  AR_CONFIGURATIONS_SHAREABLE = nil

  # Shareable (deep-frozen) copy of DatabaseConfigurations.db_config_handlers
  # (an Array of shareable handler Procs) captured at prepare time. Workers
  # read this instead of the per-Ractor class instance variable.
  AR_DB_CONFIG_HANDLERS_SHAREABLE = nil

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
        # Build a plain Hash snapshot of every db config keyed by
        # [env_name][config_name]. ActiveRecord::Base.configurations is a
        # DatabaseConfigurations object that does not respond to #each in
        # this Rails/Ruby, so read the underlying config from
        # Rails.application.config.database_configuration (a Hash of
        # env => { name => config }) which is stable across versions.
        raw = ::Rails.application.config.database_configuration rescue {}
        snapshot = {}
        raw.each do |env_name, env_configs|
          next unless env_configs.is_a?(::Hash)
          snapshot[env_name] ||= {}
          env_configs.each do |name, config|
            next unless config.is_a?(::Hash)
            # Drop nil values so Ractor.make_shareable sees a clean,
            # shareable Hash of simple literals.
            snapshot[env_name][name] = config.reject { |_k, v| v.nil? }
          end
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

      # Establish a fresh, per-Ractor connection handler + pool from the
      # captured configurations snapshot. We call ConnectionHandler#establish_connection
      # DIRECTLY (not ActiveRecord::Base.establish_connection, which writes
      # the `@resolved_config` class ivar from the worker -> IsolationError).
      # ConnectionHandler#establish_connection reads ActiveRecord::Base.configurations
      # (now IES-routed by _install_activerecord_configurations_patch) inside
      # resolve_pool_config, so it works from a worker. Best-effort per config.
      snapshot = AR_CONFIGURATIONS_SNAPSHOT
      if snapshot && !snapshot.empty?
        env = ENV["RAILS_ENV"].presence || ENV["RACK_ENV"].presence || "development"
        env_configs = snapshot[env] || snapshot.values.first || {}

        handler = ::ActiveRecord::ConnectionAdapters::ConnectionHandler.new
        env_configs.each do |_name, config|
          begin
            handler.establish_connection(config,
              owner_name: ::ActiveRecord::Base,
              role: ::ActiveRecord::Base.current_role || :writing,
              shard: ::ActiveRecord::Base.current_shard || :default)
          rescue => e
            # Best-effort: if one connection fails, continue with others.
          end
        end

        ActiveSupport::IsolatedExecutionState[key] = handler
      end
    end

    # Blockers 3: ActiveRecord model classes cache relation-delegate classes
    # in the `@relation_delegate_cache` class instance variable (set in
    # `DelegateCache#initialize_relation_delegate_cache`,
    # activerecord/relation/delegation.rb:31-44). The cache is a plain (mutable)
    # Hash mapping each delegated class (ActiveRecord::Relation, etc.) to an
    # anonymous delegate Class. From a worker Ractor, reading the class ivar
    # raises Ractor::IsolationError ("can not get unshareable values from
    # instance variables of classes/modules from non-main Ractors
    # (@relation_delegate_cache from Post)") — even a plain `Post.page(1)`.
    #
    # The delegate Classes themselves ARE shareable (verified:
    # Ractor.shareable?(Post::ActiveRecord_Relation) == true). Only the
    # enclosing Hash is mutable (unshareable). So we deep-freeze the cache
    # (Ractor.make_shareable) in the main Ractor at prepare/make-shareable
    # time. A class ivar whose value is shareable is readable from a worker
    # Ractor (unlike class variables, which always raise). Freezing is safe:
    # the cache is populated once per class at load time and never mutated
    # afterwards (each relation-delegate Class is const_set as a private
    # constant on the model class).
    def _install_activerecord_relation_delegate_cache_patch
      return if @ar_rdc_patched
      @ar_rdc_patched = true
      _register_patch :activerecord_relation_delegate_cache, "8.1"
      return unless defined?(::ActiveRecord::Base)
      _share_relation_delegate_caches! if Ractor.main?
    end

    # Make every loaded AR model class's @relation_delegate_cache shareable.
    # Idempotent; must run in the main Ractor after eager_load so that all
    # model classes (and their caches) exist.
    def _share_relation_delegate_caches!
      return unless defined?(::ActiveRecord::Base)
      classes = [::ActiveRecord::Base]
      classes.concat(::ActiveRecord::Base.descendants) rescue nil
      classes.each do |klass|
        cache = klass.instance_variable_get(:@relation_delegate_cache) rescue nil
        next unless cache
        next if Ractor.shareable?(cache)
        begin
          klass.instance_variable_set(:@relation_delegate_cache,
            Ractor.make_shareable(cache))
        rescue => e
          # Best-effort: if a cache holds an unshareable delegate class we
          # can't freeze, skip it. The worker will then hit a clear error on
          # the first relation method and we can patch that class specifically.
        end
      end
    end

    # ActiveRecord model classes lazily initialize many class instance
    # variables on first use (e.g. @table_name, @arel_table, @predicate_builder,
    # @columns_hash, @attribute_methods_module) via `@ivar ||= compute`. The
    # computation is deterministic, but it WRITES the class ivar — which a
    # worker Ractor cannot do (Ractor::IsolationError: "can not set instance
    # variables of classes/modules by non-main Ractors").
    #
    # Fix: in the main Ractor, warm every model class by running representative
    # queries (count / first / page), which populates all the lazy class ivars
    # with their shareable-or-not values. Then make every class ivar's VALUE
    # shareable (deep-freeze via Ractor.make_shareable) and write it back while
    # the class is still mutable in main. A class ivar holding a shareable value
    # is readable from a worker Ractor, and the worker's `||=` short-circuits
    # (no write). Idempotent; must run in the main Ractor after eager_load.
    def _share_model_classes!
      return unless defined?(::ActiveRecord::Base)

      classes = [::ActiveRecord::Base]
      classes.concat(::ActiveRecord::Base.descendants) rescue nil
      classes.each do |klass|
        # Warm the class's lazy ivars by actually exercising the query paths
        # the workers will hit. Main has a working connection handler, so this
        # populates exactly the ivars a real query touches.
        # Warm the class's lazy ivars by actually exercising the query paths
        # the workers will hit. Main has a working connection handler, so this
        # populates exactly the ivars a real query touches. Each call is
        # isolated: a failure in one must not skip the rest (e.g. the private
        # `relation` method or a cold connection must not prevent `table_name`
        # from being set).
        warm_calls = [
          -> { klass.connection_pool if klass.respond_to?(:connection_pool) },
          -> { klass.table_name },
          -> { klass.arel_table },
          -> { klass.columns_hash },
          -> { klass.attribute_names },
          -> { klass.attribute_types },
          -> { klass.predicate_builder },
          -> { klass.defined_enums if klass.respond_to?(:defined_enums) },
          -> { klass.send(:relation) if klass.respond_to?(:relation, true) },
          -> { klass.count rescue nil },
          -> { klass.first rescue nil },
          -> { if defined?(::Kaminari) && klass.respond_to?(:page)
                 klass.page(1).to_a rescue nil
               end },
        ]
        warm_calls.each { |c| begin; c.call; rescue => e; end }

        # Make every class ivar shareable and write it back. The class is
        # still mutable here (in main), so the write is allowed.
        begin
          klass.instance_variables.each do |iv|
            v = klass.instance_variable_get(iv) rescue nil
            next unless v
            next if Ractor.shareable?(v)
            replacement = _shareable_ivar_replacement(v)
            next unless replacement
            begin
              klass.instance_variable_set(iv, replacement)
            rescue => e
              # frozen owner — leave as-is
            end
          end
        rescue => e
          # BasicObject / frozen owners
        end
      end
    end

    # Compute a shareable replacement for an unshareable class-ivar value:
    #  - Monitor/Mutex  -> NoOpLock (never contended post-boot)
    #  - Concurrent::Map -> frozen Hash
    #  - else           -> Ractor.make_shareable; if that fails (statement
    #                      caches etc.), a frozen empty container of the same
    #                      kind so the worker reads a shareable value (cold
    #                      cache in workers; slower, correct). Returns nil if
    #                      no replacement can be made.
    def _shareable_ivar_replacement(v)
      if v.is_a?(::Monitor) || v.is_a?(::Mutex)
        Ractor.make_shareable(NoOpLock.new)
      elsif defined?(::Concurrent::Map) && v.is_a?(::Concurrent::Map)
        h = {}
        begin
          v.each_pair { |k, val| h[k] = val }
        rescue => e
        end
        Ractor.make_shareable(h)
      else
        begin
          Ractor.make_shareable(v)
        rescue => e
          case v
          when ::Hash then Ractor.make_shareable({})
          when ::Array then Ractor.make_shareable([])
          when ::Set then Ractor.make_shareable(::Set.new)
          else nil
          end
        end
      end
    end

    # ActiveRecord's internal helper classes (the *Clause classes used while
    # building a relation's Arel) cache a frozen "empty" singleton in a class
    # instance variable via `@empty ||= new(...).freeze` (e.g.
    # ActiveRecord::Relation::WhereClause#empty). Reading that class ivar from
    # a worker Ractor raises Ractor::IsolationError if the value isn't
    # shareable. Fix: warm `.empty` in the main Ractor (populating @empty with
    # its frozen singleton), then make every class ivar on these helper
    # classes shareable. Idempotent; must run in the main Ractor.
    # ActiveRecord's internal helper classes/modules hold class instance
    # variables that a worker Ractor reads during query building / connection
    # establishment (e.g. `ActiveRecord::ConnectionAdapters.@adapters` — a Hash
    # of adapter_name => [class_name, path]; the `*Clause` classes' `@empty`
    # frozen singleton). A class ivar whose VALUE is shareable IS readable from
    # a worker Ractor (unlike class variables), so we deep-freeze each value
    # in the main Ractor and write it back (Monitor/Mutex->NoOpLock,
    # Concurrent::Map->frozen Hash, etc. via _shareable_ivar_replacement).
    #
    # TARGETED: only specific leaf registries (not a broad ActiveRecord::*
    # sweep). A broad sweep also freezes AR-railtie initializer Collections
    # reachable from the app graph, which breaks make_app_shareable's
    # proc-replacement (frozen containers can't be mutated to swap Procs).
    def _share_active_record_internals!
      return unless defined?(::ActiveRecord::Base)

      # 1. Warm + freeze the *Clause `.empty` singletons.
      ObjectSpace.each_object(Class) do |c|
        n = c.name
        next unless n && n.start_with?("ActiveRecord::Relation::") &&
                    n.end_with?("Clause")
        begin
          c.empty if c.respond_to?(:empty)
        rescue => e
        end
        _freeze_class_ivars!(c)
      end

      # 2. ConnectionAdapters.@adapters (String => [class_name, path]) — read
      #    by `ConnectionAdapters.resolve` during establish_connection.
      if defined?(::ActiveRecord::ConnectionAdapters)
        _freeze_class_ivars!(::ActiveRecord::ConnectionAdapters)
      end
    end

    # Make every unshareable class ivar on `owner` shareable (deep-freeze) and
    # write it back. A class ivar holding a shareable value is readable from a
    # worker Ractor. Monitor/Mutex->NoOpLock; Concurrent::Map->frozen Hash;
    # values that can't be frozen (Procs, TypeMap) are left as-is.
    def _freeze_class_ivars!(owner)
      begin
        owner.instance_variables.each do |iv|
          v = owner.instance_variable_get(iv) rescue nil
          next unless v
          next if Ractor.shareable?(v)
          replacement = _shareable_ivar_replacement(v)
          next unless replacement
          begin
            owner.instance_variable_set(iv, replacement)
          rescue => e
            # frozen owner — leave as-is
          end
        end
      rescue => e
      end
    end

    # Register + run the model-class shareability patch (Blocker: AR model
    # class lazy class-ivar initialization from workers).
    def _install_activerecord_model_classes_patch
      return if @ar_model_classes_patched
      @ar_model_classes_patched = true
      _register_patch :activerecord_model_classes, "8.1"
      return unless defined?(::ActiveRecord::Base)
      _share_model_classes! if Ractor.main?
      _share_active_record_internals! if Ractor.main?
    end

    # Patch ActiveRecord::Core.configurations / configurations= to route the
    # raw `@@configurations` class variable (which a non-main Ractor cannot
    # read or write) through IsolatedExecutionState, with a shareable
    # (deep-frozen) fallback for worker Ractors. Connection establishment in a
    # worker (`ConnectionHandler#establish_connection` -> `resolve_pool_config`
    # -> `ActiveRecord::Base.configurations`) otherwise dies on the class
    # variable. Captured in the main Ractor at prepare/make-shareable time.
    def _install_activerecord_configurations_patch
      return if @ar_configurations_patched
      @ar_configurations_patched = true
      _register_patch :activerecord_configurations, "8.1"
      return unless defined?(::ActiveRecord::Core)

      if Ractor.main?
        begin
          cfg = ::ActiveRecord::Base.configurations
          cfg = Ractor.make_shareable(cfg) if cfg
          if cfg
            verbose, $VERBOSE = $VERBOSE, nil
            begin
              const_set(:AR_CONFIGURATIONS_SHAREABLE, cfg)
            ensure
              $VERBOSE = verbose
            end
          end
        rescue => e
          # best-effort
        end
      end

      key = :ractor_rails_shim_ar_configurations
      key_str = key.inspect
      # ActiveRecord::Base gets `configurations` via ActiveSupport::Concern's
      # `class_methods` (it copies the method onto Base's singleton class), so
      # patching Core.singleton_class alone is not enough — redefine on Base's
      # singleton class directly. `@@configurations` resolves through the
      # include chain (Core's class var) in the main ractor; the worker branch
      # never touches the class var.
      ::ActiveRecord::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def configurations
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main?
            @@configurations
          else
            RactorRailsShim::AR_CONFIGURATIONS_SHAREABLE
          end
        end
        def configurations=(config)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = config
          @@configurations = config if Ractor.main?
        end
      RUBY
    end

    # Patch ActiveRecord::DatabaseConfigurations.db_config_handlers (a
    # `singleton_class.attr_accessor`, i.e. a class instance variable on the
    # DatabaseConfigurations class) to route through IES with a shareable
    # fallback. The value is an Array of adapter-registered handler Procs
    # (`register_db_config_handler { |env,name,url,config| ... }`). Class
    # instance variables are per-Ractor, so a worker's slot is empty even if
    # main set one — and the worker cannot read main's. The handler Procs
    # themselves CAN be made shareable (verified: the sqlite3 handler captures
    # only the shareable HashConfig constant), so we deep-freeze the Array +
    # each Proc in main and expose it as a shareable constant the worker reads.
    # `ConnectionHandler#establish_connection` -> `resolve_pool_config` ->
    # `DatabaseConfigurations#resolve` -> `build_db_config_from_hash` calls
    # these Procs, so they must be shareable AND callable cross-Ractor.
    def _install_activerecord_db_config_handlers_patch
      return if @ar_dbch_patched
      @ar_dbch_patched = true
      _register_patch :activerecord_db_config_handlers, "8.1"
      return unless defined?(::ActiveRecord::DatabaseConfigurations)

      if Ractor.main?
        begin
          handlers = ::ActiveRecord::DatabaseConfigurations.db_config_handlers
          # Make each handler Proc shareable (freezes its binding). A shareable
          # Proc is callable from any Ractor.
          handlers.each { |h| Ractor.make_shareable(h) rescue nil }
          shareable = Ractor.make_shareable(handlers.dup)
          verbose, $VERBOSE = $VERBOSE, nil
          begin
            const_set(:AR_DB_CONFIG_HANDLERS_SHAREABLE, shareable)
          ensure
            $VERBOSE = verbose
          end
        rescue => e
          # best-effort
        end
      end

      key = :ractor_rails_shim_ar_db_config_handlers
      key_str = key.inspect
      ::ActiveRecord::DatabaseConfigurations.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def db_config_handlers
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main?
            @db_config_handlers
          else
            RactorRailsShim::AR_DB_CONFIG_HANDLERS_SHAREABLE
          end
        end
        def db_config_handlers=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
          @db_config_handlers = val if Ractor.main?
        end
      RUBY
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

    # A shareable Rack middleware that ensures each worker Ractor establishes
    # its own ActiveRecord connection handler on the first request it serves.
    # Kino's `:ractor` mode has no per-worker init hook, so the connection
    # must be initialized lazily inside the worker Ractor's request path.
    # `init_worker_ar_connections!` is idempotent (it early-returns once the
    # per-Ractor IES slot holds a handler), so calling it on every request is
    # cheap after the first. The wrapper holds only `@app` (shareable), so the
    # wrapper itself is `Ractor.make_shareable`.
    #
    # Usage in a kino `config_ractor.ru`:
    #   app = RactorRailsShim.make_app_shareable!(Rails.application)
    #   app = RactorRailsShim.worker_ar_init(app)
    #   run app
    class ArWorkerInitWrapper
      def initialize(app)
        @app = app
      end

      def call(env)
        RactorRailsShim.init_worker_ar_connections!
        @app.call(env)
      end
    end

    # Wrap `app` so every worker Ractor initializes its ActiveRecord
    # connections on first request. Returns a shareable wrapper.
    def worker_ar_init(app)
      ArWorkerInitWrapper.new(app)
    end
  end
end
