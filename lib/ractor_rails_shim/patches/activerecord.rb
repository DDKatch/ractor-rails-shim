# frozen_string_literal: true

# Patch ActiveRecord's connection handler to work in per-Ractor mode.
#
# Blocker 1:
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
    "ActiveRecord::Delegation::GeneratedRelationMethods::MUTEX",
  ])

  # Shareable replacements for Arel::Visitors::*::BIND_BLOCK constants.
  # These are Procs (e.g. `proc { |i| "$#{i}" }`) used to format bind
  # parameters in SQL. Procs can't be made shareable. We patch the `bind_block`
  # method to return a shareable Callable instead (defined via string eval,
  # no captured binding).
  class << self
    def _install_arel_bind_block_patch
      return if @arel_bind_block_patched
      @arel_bind_block_patched = true
      _register_patch :arel_bind_block, "8.1"

      # PostgreSQL: proc { |i| "$#{i}" }
      if defined?(::Arel::Visitors::PostgreSQL)
        ::Arel::Visitors::PostgreSQL.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def bind_block
            RactorRailsShim::PgBindBlock
          end
        RUBY
      end

      # ToSql (base): proc { "?" }
      if defined?(::Arel::Visitors::ToSql)
        ::Arel::Visitors::ToSql.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def bind_block
            RactorRailsShim::SqlBindBlock
          end
        RUBY
      end
    end
  end

  # Shareable snapshot of each AR model class's primary_key, captured at
  # prepare time. Workers read this instead of the raw @primary_key class ivar
  # (which is initialized to PRIMARY_KEY_NOT_SET, a BasicObject that can't be
  # made shareable). Populated by _share_model_classes! in the main ractor.
  AR_PRIMARY_KEYS_SHAREABLE = Ractor.make_shareable({})

  # Shareable callable that replaces Arel::Visitors::PostgreSQL::BIND_BLOCK
  # (a Proc `proc { |i| "$#{i}" }`). Callable cross-Ractor.
  PgBindBlock = Ractor.make_shareable(Object.new.tap do |o|
    def o.call(i); "$#{i}"; end
    def o.to_proc; method(:call).to_proc; end
  end)

  # Shareable callable that replaces Arel::Visitors::ToSql::BIND_BLOCK
  # (a Proc `proc { "?" }`). Callable cross-Ractor.
  SqlBindBlock = Ractor.make_shareable(Object.new.tap do |o|
    def o.call(_i = nil); "?"; end
    def o.to_proc; method(:call).to_proc; end
  end)

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

  # Shareable (deep-frozen) copy of ActiveRecord.query_transformers (an Array
  # of transformer classes/objects) captured at prepare time. Workers read this
  # instead of the per-Ractor class instance variable.
  AR_QUERY_TRANSFORMERS_SHAREABLE = nil

  # Capture the db configurations from the main ractor at
  # prepare_for_actors! / make_app_shareable! time. This is a shareable
  # snapshot (frozen Hash of config hashes) that workers use to establish
  # their own connection pools. Must run in the main Ractor.
  class << self
    def _capture_ar_configurations!
      return if @_ar_configs_captured
      @_ar_configs_captured = true
      return unless defined?(::ActiveRecord::Base)

      begin
        # Build a plain Hash snapshot of every db config keyed by
        # [env_name][config_name] => config_hash. Use
        # ActiveRecord::Base.configurations.configs_for (returns DbConfig
        # objects with .name, .env_name, .configuration_hash) rather than
        # Rails.application.config.database_configuration (a legacy Hash whose
        # shape differs between single-config apps (flat Hash = the config
        # itself) and multi-config apps (nested Hash of name => config)).
        cfgs = ::ActiveRecord::Base.configurations
        snapshot = {}
        if cfgs.respond_to?(:configs_for)
          cfgs.configs_for.each do |dc|
            env_name = dc.env_name
            name = dc.name || "primary"
            hash = dc.configuration_hash
            next unless hash.is_a?(::Hash)
            snapshot[env_name] ||= {}
            snapshot[env_name][name] = hash.reject { |_k, v| v.nil? }
          end
        end
        # Fallback: legacy database_configuration Hash (env => { name => config }
        # OR env => flat config). Used if configs_for is unavailable.
        if snapshot.empty?
          raw = ::Rails.application.config.database_configuration rescue {}
          raw.each do |env_name, env_configs|
            next unless env_configs.is_a?(::Hash)
            snapshot[env_name] ||= {}
            if env_configs.key?("adapter") || env_configs.key?(:adapter)
              # Flat config: the env value IS the "primary" config itself.
              snapshot[env_name]["primary"] = env_configs.reject { |_k, v| v.nil? }
            else
              # Nested: env => { name => config }
              env_configs.each do |name, config|
                next unless config.is_a?(::Hash)
                snapshot[env_name][name] = config.reject { |_k, v| v.nil? }
              end
            end
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
      # Store the handler in Ractor-local storage (Ractor.current), NOT in
      # ActiveSupport::IsolatedExecutionState. IES is per-THREAD (it is a
      # Thread.attr_accessor), so a value set on the init thread is invisible
      # to the other worker threads in the same worker Ractor ->
      # ConnectionNotEstablished ("No connection handler for Ractor X").
      # Ractor.current storage is per-Ractor and shared by every thread of the
      # worker, so connection_handler resolves the same handler for all threads.
      existing = Ractor.current[key]
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

        Ractor.current[key] = handler
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

      mod = ::ActiveRecord::Delegation::DelegateCache
      mod.module_eval do
        # The default implementation reads the delegate class from the
        # `@relation_delegate_cache` *class instance variable* — an unshareable
        # Hash populated lazily on the model class. From a worker Ractor that
        # value is unreadable (Ractor::IsolationError: "can not get unshareable
        # values from instance variables ... (@relation_delegate_cache from
        # Post)"). `initialize_relation_delegate_cache` ALSO const_sets each
        # delegate class onto the model (e.g. `Post::ActiveRecord_Relation`),
        # and that constant is shareable. So read the delegate class via the
        # constant instead of the class ivar — Ractor-safe with no per-worker
        # rebuild.
        def relation_delegate_class(klass)
          const_get(klass.name.gsub("::", "_"))
        end

        # Keep building + const_setting the delegate classes (shareable), but
        # stop stashing them in the unshareable `@relation_delegate_cache` ivar.
        # The ivar is left a frozen empty Hash so any (now-unused) reader of it
        # is still Ractor-safe.
        def initialize_relation_delegate_cache
          @relation_delegate_cache = {}.freeze
          ::ActiveRecord::Delegation.delegated_classes.each do |k|
            delegate = Class.new(k) { include ::ActiveRecord::Delegation::ClassSpecificRelation }
            include_relation_methods(delegate)
            mangled_name = k.name.gsub("::", "_")
            const_set mangled_name, delegate
            private_constant mangled_name
          end
        end
      end

      _share_relation_delegate_caches! if Ractor.main?
    end

    # ActiveModel::AttributeMethods::ClassMethods#attribute_method_patterns_cache
    # stores a mutable Concurrent::Map in a CLASS instance variable
    # (@attribute_method_patterns_cache). That ivar is unshareable, so reading
    # it from a worker Ractor raises Ractor::IsolationError ("can not get
    # unshareable values from instance variables of classes/modules from
    # non-main Ractors") — hit on the write path via redirect_to @post ->
    # respond_to? -> matched_attribute_method -> attribute_method_patterns_cache.
    #
    # Unlike @relation_delegate_cache (populated once, freezable), this map is
    # mutated lazily per method_name (compute_if_absent) during request handling,
    # so it cannot be frozen. Instead route it through Ractor-local storage:
    # each Ractor gets its own Concurrent::Map, shared by all of its threads.
    # The cache content is deterministic (a pure function of the class's
    # attribute_method_patterns), so per-Ractor recomputation is correct.
    def _install_active_model_attribute_method_patterns_patch
      return if @am_amp_patched
      @am_amp_patched = true
      _register_patch :active_model_attribute_method_patterns, "8.1"
      return unless defined?(::ActiveModel::AttributeMethods)

      mod = ::ActiveModel::AttributeMethods::ClassMethods
      mod.module_eval do
        def attribute_method_patterns_cache
          store = Ractor.current[:__am_attribute_method_patterns_cache__] ||= {}
          store[object_id] ||= Concurrent::Map.new(initial_capacity: 4)
        end
      end
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
          -> { klass.send(:reset_primary_key) if klass.respond_to?(:reset_primary_key, true) },
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
          -> { klass.send(:query_constraints_list) if klass.respond_to?(:query_constraints_list, true) },
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

      # Capture each model's primary_key into a shareable snapshot. Workers
      # read this instead of the raw @primary_key class ivar (which starts as
      # PRIMARY_KEY_NOT_SET, a BasicObject that can't be made shareable).
      begin
        pk_map = {}
        classes.each do |klass|
          n = klass.name
          next unless n
          pk = klass.primary_key rescue next
          pk_map[n] = pk if pk
        end
        shareable = Ractor.make_shareable(pk_map)
        verbose, $VERBOSE = $VERBOSE, nil
        begin
          const_set(:AR_PRIMARY_KEYS_SHAREABLE, shareable)
        ensure
          $VERBOSE = verbose
        end
      rescue => e
        # best-effort
      end
    end
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

      # 3. ActiveRecord::Type — holds @default_value (a lazy singleton Value
      #    used as a fallback type). Warm it and freeze the class ivar.
      if defined?(::ActiveRecord::Type)
        ::ActiveRecord::Type.default_value rescue nil
        _freeze_class_ivars!(::ActiveRecord::Type)
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

    # Patch ActiveRecord::ModelSchema::ClassMethods so worker Ractors do not
    # write the `@table_name` (and related) class ivars on the shared model
    # class. `table_name` memoizes via `reset_table_name unless
    # defined?(@table_name)`, and `reset_table_name` calls `self.table_name =`
    # which writes `@table_name`/`@arel_table`/etc. From a worker that write is
    # Ractor::IsolationError. Route the value through IsolatedExecutionState
    # (keyed by model object_id); main keeps the original class-ivar behavior.
    def _install_active_record_model_schema_patch
      return if @ar_model_schema_patched
      @ar_model_schema_patched = true
      _register_patch :active_record_model_schema, "8.1"
      return unless defined?(::ActiveRecord::ModelSchema::ClassMethods)
      mod = ::ActiveRecord::ModelSchema::ClassMethods
      mod.module_eval do
        def table_name
          if Ractor.main?
            reset_table_name unless defined?(@table_name)
            @table_name
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_table_names] ||= {})
            store.fetch(object_id) { store[object_id] = compute_table_name }
          end
        end

        def table_name=(value)
          value = value && value.to_s
          if Ractor.main?
            if defined?(@table_name)
              return if value == @table_name
              reset_column_information if connected?
            end
            @table_name        = value
            @arel_table        = nil
            @sequence_name     = nil unless @explicit_sequence_name
            @predicate_builder = nil
          else
            (ActiveSupport::IsolatedExecutionState[:rrs_table_names] ||= {})[object_id] = value
          end
        end

        def reset_table_name
          if Ractor.main?
            super
          else
            table_name
          end
        end
      end
    end

    # Patch ActiveRecord::Core::ClassMethods#arel_table / #predicate_builder /
    # #type_caster. Each memoizes an unshareable value (@arel_table is an
    # Arel::Table, @predicate_builder a PredicateBuilder) on the shared model
    # class. From a worker Ractor the `||=` write raises Ractor::IsolationError,
    # and reading the unshareable cached value also raises. Build + cache each
    # per-Ractor via IsolatedExecutionState (keyed by model object_id); main
    # keeps the original class-ivar behavior.
    def _install_active_record_core_patch
      return if @ar_core_patched
      @ar_core_patched = true
      _register_patch :active_record_core, "8.1"
      return unless defined?(::ActiveRecord::Core::ClassMethods)
      mod = ::ActiveRecord::Core::ClassMethods
      mod.module_eval do
        def arel_table
          if Ractor.main?
            @arel_table ||= ::Arel::Table.new(table_name, klass: self)
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_arel_tables] ||= {})
            store.fetch(object_id) { store[object_id] = ::Arel::Table.new(table_name, klass: self) }
          end
        end

        def predicate_builder
          if Ractor.main?
            @predicate_builder ||= ::ActiveRecord::PredicateBuilder.new(
              ::ActiveRecord::TableMetadata.new(self, arel_table))
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_predicate_builders] ||= {})
            store.fetch(object_id) do
              store[object_id] = ::ActiveRecord::PredicateBuilder.new(
                ::ActiveRecord::TableMetadata.new(self, arel_table))
            end
          end
        end

        def type_caster
          if Ractor.main?
            @type_caster ||= ::ActiveRecord::TypeCaster::Map.new(self)
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_type_casters] ||= {})
            store.fetch(object_id) { store[object_id] = ::ActiveRecord::TypeCaster::Map.new(self) }
          end
        end
      end
    end

    # Patch ActiveRecord::Inheritance::ClassMethods#finder_needs_type_condition?.
    # It memoizes `@finder_needs_type_condition` (a Symbol) on the shared model
    # class via `@ivar ||=`. From a worker Ractor that write raises
    # Ractor::IsolationError. Route the value through IsolatedExecutionState
    # (keyed by model object_id); main keeps the original class-ivar behavior.
    def _install_active_record_inheritance_patch
      return if @ar_inheritance_patched
      @ar_inheritance_patched = true
      _register_patch :active_record_inheritance, "8.1"
      return unless defined?(::ActiveRecord::Inheritance::ClassMethods)
      mod = ::ActiveRecord::Inheritance::ClassMethods
      mod.module_eval do
        def finder_needs_type_condition?
          if Ractor.main?
            :true == (@finder_needs_type_condition ||= descends_from_active_record? ? :false : :true)
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_finder_type_cond] ||= {})
            store.fetch(object_id) do
              store[object_id] = descends_from_active_record? ? false : true
            end
          end
        end
      end
    end
    # (an ActiveModel::Name holding unfrozen, unshareable Strings) on the model
    # class. From a worker Ractor that write raises Ractor::IsolationError ("can
    # not set instance variables of classes/modules by non-main Ractors") and
    # reading the unshareable value raises too. Route the cache through
    # IsolatedExecutionState (keyed by model object_id) so each Ractor builds
    # and keeps its own ActiveModel::Name without touching the shared class
    # ivar.
    def _install_active_model_naming_patch
      return if @am_naming_patched
      @am_naming_patched = true
      _register_patch :active_model_naming, "8.1"
      return unless defined?(::ActiveModel::Naming)
      mod = ::ActiveModel::Naming
      mod.module_eval do
        def model_name
          if Ractor.main?
            @_model_name ||= _rrs_compute_model_name
          else
            store = (ActiveSupport::IsolatedExecutionState[:rrs_model_names] ||= {})
            store[object_id] ||= _rrs_compute_model_name
          end
        end

        private

        def _rrs_compute_model_name
          namespace = module_parents.detect do |n|
            n.respond_to?(:use_relative_model_naming?) && n.use_relative_model_naming?
          end
          ::ActiveModel::Name.new(self, namespace)
        end
      end
    end

    # Patch ActiveRecord::ModelSchema::ClassMethods lazy class-ivar caches
    # (`symbol_column_to_string`, `content_columns`, `column_defaults`) to
    # route through IsolatedExecutionState. Each Ractor builds its own cache
    # (deterministic from `columns`/`columns_hash`, which are warmed in main
    # and read-only in workers). Without this, the first worker call that
    # misses the cache tries to WRITE the class ivar (`@symbol_column_to_string_name_hash
    # ||= ...`) and dies with `Ractor::IsolationError: can not set instance
    # variables of classes/modules by non-main Ractors`. Seen via Devise's
    # `clean_up_passwords` -> `respond_to?` -> `symbol_column_to_string`.
    def _install_activerecord_model_schema_patch
      return if @ar_model_schema_symbol_patched
      @ar_model_schema_symbol_patched = true
      _register_patch :activerecord_model_schema, "8.1"
      return unless defined?(::ActiveRecord::ModelSchema)

      ::ActiveRecord::ModelSchema::ClassMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def symbol_column_to_string(name_symbol)
          key = :"ractor_rails_shim_symbol_column_to_string_\#{self.name}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v[name_symbol] if v
          hash = column_names.index_by(&:to_sym)
          ActiveSupport::IsolatedExecutionState[key] = hash
          hash[name_symbol]
        end

        def content_columns
          key = :"ractor_rails_shim_content_columns_\#{self.name}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v if v
          cols = columns.reject do |c|
            c.name == primary_key ||
            c.name == inheritance_column ||
            c.name.end_with?("_id", "_count")
          end.freeze
          ActiveSupport::IsolatedExecutionState[key] = cols
          cols
        end

        def column_defaults
          key = :"ractor_rails_shim_column_defaults_\#{self.name}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v if v
          defaults = _default_attributes.deep_dup.to_hash.freeze
          ActiveSupport::IsolatedExecutionState[key] = defaults
          defaults
        end
      RUBY
    end

    # Patch ActiveModel::Conversion::ClassMethods#_to_partial_path to route its
    # lazy class-ivar cache (`@_to_partial_path ||= ...`) through
    # IsolatedExecutionState. The cache holds a deterministic String derived
    # from `model_name`, so each Ractor can build its own. Without this, the
    # first `render @posts` / `render post` in a worker Ractor writes the class
    # ivar and dies with `Ractor::IsolationError: can not set instance variables
    # of classes/modules by non-main Ractors`. Seen via ActionView's
    # `CollectionRenderer#render_collection_derive_partial` -> `to_partial_path`.
    def _install_active_model_conversion_patch
      return if @active_model_conversion_patched
      @active_model_conversion_patched = true
      _register_patch :active_model_conversion, "8.1"
      return unless defined?(::ActiveModel::Conversion)
      amc = ::ActiveModel::Conversion
      amc.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        module ClassMethods
          def _to_partial_path
            key = :"ractor_rails_shim_to_partial_path_\#{name}"
            v = ActiveSupport::IsolatedExecutionState[key]
            return v if v
            path = if respond_to?(:model_name)
              "\#{model_name.collection}/\#{model_name.element}"
            else
              element = ActiveSupport::Inflector.underscore(ActiveSupport::Inflector.demodulize(name))
              collection = ActiveSupport::Inflector.tableize(name)
              "\#{collection}/\#{element}"
            end
            path = path.freeze
            ActiveSupport::IsolatedExecutionState[key] = path
            path
          end
        end
      RUBY
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
            ActiveRecord::Core.class_variable_get(:@@configurations)
          else
            RactorRailsShim::AR_CONFIGURATIONS_SHAREABLE
          end
        end
        def configurations=(config)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = config
          ActiveRecord::Core.class_variable_set(:@@configurations, config) if Ractor.main?
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

    # Patch ActiveRecord.query_transformers to route through IES with a
    # shareable fallback. `query_transformers` is a `singleton_class
    # .attr_accessor` (a class instance variable on the `ActiveRecord` module)
    # holding an Array of transformer objects (e.g. `ActiveRecord::QueryLogs`).
    # `DatabaseStatements#preprocess_query` reads it on every query:
    # `ActiveRecord.query_transformers.each { |t| t.call(sql, self) }`.
    #
    # Class instance variables are per-Ractor, so a worker's `@query_transformers`
    # is nil (set in main at boot via `self.query_transformers = []`, then
    # `<< QueryLogs` in the railtie). The transformer objects themselves ARE
    # shareable (they're Classes/modules), so we deep-freeze the Array in main
    # and expose it as a shareable constant the worker reads. Same pattern as
    # `_install_activerecord_db_config_handlers_patch`.
    def _install_activerecord_query_transformers_patch
      return if @ar_query_transformers_patched
      @ar_query_transformers_patched = true
      _register_patch :activerecord_query_transformers, "8.1"
      return unless defined?(::ActiveRecord)

      if Ractor.main?
        begin
          transformers = ::ActiveRecord.query_transformers
          transformers.each { |t| Ractor.make_shareable(t) rescue nil }
          shareable = Ractor.make_shareable(transformers.dup)
          verbose, $VERBOSE = $VERBOSE, nil
          begin
            const_set(:AR_QUERY_TRANSFORMERS_SHAREABLE, shareable)
          ensure
            $VERBOSE = verbose
          end
        rescue => e
          # best-effort
        end
      end

      key = :ractor_rails_shim_ar_query_transformers
      key_str = key.inspect
      ::ActiveRecord.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def query_transformers
          v = ActiveSupport::IsolatedExecutionState[#{key_str}]
          return v unless v.nil?
          if Ractor.main?
            @query_transformers
          else
            RactorRailsShim::AR_QUERY_TRANSFORMERS_SHAREABLE
          end
        end
        def query_transformers=(val)
          ActiveSupport::IsolatedExecutionState[#{key_str}] = val
          @query_transformers = val if Ractor.main?
        end
      RUBY
    end

    # Patch ActiveRecord module-level singleton_class.attr_accessor attributes
    # (schema_cache_ignored_tables, database_cli, etc.) to route through IES
    # with shareable fallbacks. These are class instance variables on the
    # `ActiveRecord` module that workers can't read/write. Each is an Array or
    # Hash of simple literals, so they can be deep-frozen and shared.
    def _install_activerecord_module_attrs_patch
      return if @ar_module_attrs_patched
      @ar_module_attrs_patched = true
      _register_patch :activerecord_module_attrs, "8.1"
      return unless defined?(::ActiveRecord)

      # [method_name, const_name] pairs. The const holds the shareable snapshot.
      attrs = [
        [:schema_cache_ignored_tables, :AR_SCHEMA_CACHE_IGNORED_TABLES_SHAREABLE],
        [:database_cli, :AR_DATABASE_CLI_SHAREABLE],
      ]

      attrs.each do |method_name, const_name|
        if Ractor.main?
          begin
            val = ::ActiveRecord.public_send(method_name)
            shareable = Ractor.make_shareable(val.is_a?(::Array) ? val.dup : val)
            verbose, $VERBOSE = $VERBOSE, nil
            begin
              const_set(const_name, shareable)
            ensure
              $VERBOSE = verbose
            end
          rescue => e
            # best-effort
          end
        end

        key = :"ractor_rails_shim_ar_#{method_name}"
        key_str = key.inspect
        const_str = const_name.to_s
        ::ActiveRecord.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{method_name}
            v = ActiveSupport::IsolatedExecutionState[#{key_str}]
            return v unless v.nil?
            if Ractor.main?
              @#{method_name}
            else
              RactorRailsShim::#{const_str}
            end
          end
          def #{method_name}=(val)
            ActiveSupport::IsolatedExecutionState[#{key_str}] = val
            @#{method_name} = val if Ractor.main?
          end
        RUBY
      end
    end

    # Patch Deduplicable::ClassMethods#registry to route the lazy class instance
    # variable @registry through IES. `registry` returns `@registry ||= {}` —
    # a mutable Hash used to deduplicate column metadata objects. It's called
    # during schema introspection (`Post.all` -> `columns` -> `new_column_from_field`
    # -> `fetch_type_metadata` -> `Deduplicable.new` -> `deduplicate` -> `registry`).
    # The class instance variable write fails from a non-main Ractor.
    # Fix: route through IES so each Ractor builds its own registry Hash.
    def _install_activerecord_deduplicable_patch
      return if @ar_deduplicable_patched
      @ar_deduplicable_patched = true
      _register_patch :activerecord_deduplicable, "8.1"
      return unless defined?(::ActiveRecord::ConnectionAdapters::Deduplicable)

      ::ActiveRecord::ConnectionAdapters::Deduplicable::ClassMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def registry
          key = :"ractor_rails_shim_dedup_registry_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          h = {}
          ActiveSupport::IsolatedExecutionState[key] = h
          h
        end
      RUBY
    end

    # Patch Persistence::ClassMethods#query_constraints_list and #has_query_constraints?
    # to route the lazy @query_constraints_list class ivar through IES.
    # `query_constraints_list` does `@query_constraints_list ||= <computation>`
    # — the class ivar write fails from a non-main Ractor. Called during
    # `Post.first` -> `ordered_relation` -> `_order_columns`.
    def _install_activerecord_query_constraints_patch
      return if @ar_query_constraints_patched
      @ar_query_constraints_patched = true
      _register_patch :activerecord_query_constraints, "8.1"
      return unless defined?(::ActiveRecord::Persistence::ClassMethods)

      ::ActiveRecord::Persistence::ClassMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def query_constraints_list
          key = :"ractor_rails_shim_qcl_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          result = if base_class? || primary_key != base_class.primary_key
            primary_key if primary_key.is_a?(::Array)
          else
            base_class.query_constraints_list
          end
          ActiveSupport::IsolatedExecutionState[key] = result
          result
        end
        def has_query_constraints?
          key = :"ractor_rails_shim_qcl_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return !v.nil? unless v.nil?
          result = query_constraints_list
          !result.nil?
        end
      RUBY
    end

    # Patch ActiveRecord::ConnectionAdapters::PoolConfig#initialize to skip
    # writing to the INSTANCES ObjectSpace::WeakMap registry in non-main
    # Ractors. This is the first wall a worker hits when establishing a
    # connection (`ConnectionHandler#establish_connection` ->
    # `resolve_pool_config` -> `PoolConfig.new` -> `INSTANCES[self] = self`).
    #
    # `INSTANCES` is a `private_constant` `ObjectSpace::WeakMap`. A WeakMap is
    # intrinsically unshareable (it can't be frozen / made shareable), and a
    # non-main Ractor cannot access the constant at all (Ractor::IsolationError:
    # "can not access non-shareable objects in constant ... by non-main ractor").
    #
    # The registry is ONLY used by the class methods `discard_pools!` and
    # `disconnect_all!` (which iterate all pool configs to disconnect/reload).
    # Those are called during reloading (dev) and explicit disconnect — never
    # in a read-only production worker serving requests. So skipping the
    # registry write in workers is safe: workers manage their own per-Ractor
    # handler + pools, and the main ractor's registry stays intact for reload.
    #
    # We redefine `initialize` via string eval (no captured binding) so it's
    # callable from any Ractor. The body replicates the original exactly except
    # the final `INSTANCES[self] = self` is guarded by `Ractor.main?`. The
    # private `INSTANCES` constant is accessible via constant lookup because
    # the method is defined on PoolConfig itself.
    def _install_activerecord_pool_config_patch
      return if @ar_pool_config_patched
      @ar_pool_config_patched = true
      _register_patch :activerecord_pool_config, "8.1"
      return unless defined?(::ActiveRecord::ConnectionAdapters::PoolConfig)

      ::ActiveRecord::ConnectionAdapters::PoolConfig.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def initialize(connection_class, db_config, role, shard)
          super()
          @server_version = nil
          self.connection_descriptor = connection_class
          @db_config = db_config
          @role = role
          @shard = shard
          @pool = nil
          INSTANCES[self] = self if Ractor.main?
        end
      RUBY
    end

    # Patch ConnectionPool::Reaper#run to no-op in non-main Ractors.
    #
    # `ConnectionPool#initialize` (connection_pool.rb:307) calls `@reaper.run`,
    # which calls `Reaper.register_pool` (a class method). `register_pool`
    # reads/writes the Reaper class's instance variables (@mutex, @pools,
    # @threads — a Mutex, a Hash, and a Hash of Threads) and spawns a
    # background reaper thread. Class instance variables are off-limits to
    # non-main Ractors (Ractor::IsolationError), so this is the second wall a
    # worker hits during `establish_connection` -> `ConnectionPool.new`.
    #
    # The reaper is a background maintenance thread that periodically reaps
    # dead-thread connections, flushes idle connections, and keepalives stale
    # ones. In a worker Ractor this is neither safe (can't share the reaper
    # thread or its class-ivar registry across Ractors) nor essential: each
    # Ractor owns its own connection pool, and when the Ractor exits its pool
    # is garbage-collected with it. Connection health for long-lived workers
    # can be addressed later with a per-Ractor reaper if needed; for now,
    # no-op'ing registration unblocks connection establishment.
    #
    # `register_pool` is only called from `Reaper#run`, so patching `run` to
    # return early in non-main Ractors fully prevents the class-ivar access and
    # the thread spawn. The pool itself still functions normally.
    def _install_activerecord_reaper_patch
      return if @ar_reaper_patched
      @ar_reaper_patched = true
      _register_patch :activerecord_reaper, "8.1"
      return unless defined?(::ActiveRecord::ConnectionAdapters::ConnectionPool::Reaper)

      ::ActiveRecord::ConnectionAdapters::ConnectionPool::Reaper.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def run
          return unless frequency && frequency > 0
          return unless Ractor.main?
          self.class.register_pool(pool, frequency)
        end
      RUBY
    end

    # Patch Arel::Visitors::Visitor.dispatch_cache to route through IES.
    #
    # `dispatch_cache` is a class method that lazily initializes a class
    # instance variable: `@dispatch_cache ||= Hash.new { |hash, klass| ... }
    # .compare_by_identity`. The cache maps AST node classes to visit method
    # symbols (e.g. Arel::Nodes::SelectStatement -> :visit_Arel_Nodes_SelectStatement).
    # It's read on every Arel traversal (every query) and written on cache-miss
    # (default proc) and on method-not-found fallback (visit() rescue).
    #
    # The class instance variable `@dispatch_cache` can't be read or written by
    # a non-main Ractor (Ractor::IsolationError). The Hash also has a default
    # Proc (which is intrinsically unshareable), so the value can't be
    # frozen+shared. This is the third wall a worker hits during the first
    # query: `Post.count` -> adapter creation -> `arel_visitor` ->
    # `ToSql#initialize` -> `Visitor#initialize` -> `get_dispatch_cache` ->
    # `self.class.dispatch_cache` -> `@dispatch_cache ||= ...`.
    #
    # Fix: route through per-class IES. Each Ractor builds its own mutable
    # cache (with its own default proc) on first access. The key includes
    # `self.name` so each visitor subclass (ToSql, SQLite3, etc.) gets its own
    # cache — necessary because the method-not-found fallback
    # (`dispatch[object.class] = dispatch[superklass]`) resolves differently per
    # visitor class. The main ractor's existing `@dispatch_cache` (if any) is
    # left orphaned; new visitors created after the patch use the IES cache.
    # String-eval'd (no captured binding), callable from any Ractor.
    def _install_arel_visitor_dispatch_cache_patch
      return if @arel_visitor_patched
      @arel_visitor_patched = true
      _register_patch :arel_visitor_dispatch_cache, "8.1"
      return unless defined?(::Arel::Visitors::Visitor)

      ::Arel::Visitors::Visitor.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def dispatch_cache
          key = :"ractor_rails_shim_arel_dispatch_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v if v
          cache = Hash.new do |hash, klass|
            hash[klass] = :"visit_\#{(klass.name || "").gsub("::", "_")}"
          end.compare_by_identity
          ActiveSupport::IsolatedExecutionState[key] = cache
          cache
        end
      RUBY
    end

    # Patch the adapter quoting caches (QUOTED_COLUMN_NAMES /
    # QUOTED_TABLE_NAMES) to use per-Ractor storage instead of the
    # unshareable `Concurrent::Map` constants.
    #
    # Each adapter (SQLite3, MySQL, PostgreSQL) defines these as
    # `Concurrent::Map.new` constants in its `Quoting` module, and the
    # `quote_column_name` / `quote_table_name` class methods lazily populate
    # them via `MAP[name] ||= <quoting_logic>.freeze`. `Concurrent::Map` is
    # intrinsically unshareable (no `#freeze`), so a worker Ractor cannot
    # access the constant at all (Ractor::IsolationError: "can not access
    # non-shareable objects in constant ..."). This is the fourth wall a worker
    # hits: during `Post.count` -> Arel traversal -> `quote_table_name` ->
    # `QUOTED_TABLE_NAMES[name] ||= ...`.
    #
    # Fix: redefine `quote_column_name` / `quote_table_name` on each adapter's
    # `Quoting::ClassMethods` module to use a per-Ractor Hash cache (stored in
    # IES, keyed by the adapter class name). Each Ractor builds its own
    # mutable cache on first access. The quoting logic is replicated per
    # adapter (it's simple, stable string manipulation). String-eval'd (no
    # captured binding), callable from any Ractor.
    def _install_activerecord_quoting_cache_patch
      return if @ar_quoting_patched
      @ar_quoting_patched = true
      _register_patch :activerecord_quoting_cache, "8.1"

      # [module_path, column_logic, table_logic] per adapter.
      adapters = [
        ["ActiveRecord::ConnectionAdapters::SQLite3::Quoting",
         %q{%Q("#{name.to_s.gsub('"', '""')}").freeze},
         %q{%Q("#{name.to_s.gsub('"', '""').gsub(".", "\".\"")}").freeze}],
        ["ActiveRecord::ConnectionAdapters::MySQL::Quoting",
         %q{"`#{name.to_s.gsub('`', '``')}`".freeze},
         %q{"`#{name.to_s.gsub('`', '``').gsub(".", "`.`")}`".freeze}],
        ["ActiveRecord::ConnectionAdapters::PostgreSQL::Quoting",
         %q{::PG::Connection.quote_ident(name.to_s).freeze},
         %q{::ActiveRecord::ConnectionAdapters::PostgreSQL::Utils.extract_schema_qualified_name(name.to_s).quoted.freeze}],
      ]

      adapters.each do |mod_path, column_logic, table_logic|
        mod = begin
          mod_path.split("::").inject(Object) { |ns, n| ns.const_get(n, false) }
        rescue
          nil
        end
        next unless mod
        klass_mod = mod.const_get(:ClassMethods, false) rescue next
        next unless klass_mod.method_defined?(:quote_column_name)

        klass_mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def quote_column_name(name)
            key = :"ractor_rails_shim_quoted_cols_\#{self.name}"
            cache = ActiveSupport::IsolatedExecutionState[key]
            cache ||= (ActiveSupport::IsolatedExecutionState[key] = {})
            cache[name] ||= (#{column_logic})
          end

          def quote_table_name(name)
            key = :"ractor_rails_shim_quoted_tables_\#{self.name}"
            cache = ActiveSupport::IsolatedExecutionState[key]
            cache ||= (ActiveSupport::IsolatedExecutionState[key] = {})
            cache[name] ||= (#{table_logic})
          end
        RUBY
      end
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

      # Capture the main ractor's default_connection_handler value BEFORE we
      # override the method below (the override shadows the original
      # class_attribute reader). The class_attribute reader (already patched
      # by the shim) routes through IES, so read the value now. Store it in
      # CLASS_ATTR_VALUES so the patched reader can find it, and seed IES so
      # connection_handler finds it immediately.
      dch_key = :ractor_rails_shim_ar_default_connection_handler
      dch_key_str = dch_key.inspect
      if Ractor.main?
        begin
          orig_handler = ::ActiveRecord::Base.default_connection_handler
          if orig_handler
            RactorRailsShim::CLASS_ATTR_VALUES[:__ractor_rails_shim_ar_default_connection_handler__] = orig_handler
            ActiveSupport::IsolatedExecutionState[dch_key] = orig_handler
          end
        rescue => e
          # Best-effort
        end
      end

      # Patch default_connection_handler to route through IES.
      # The class_attribute reader for default_connection_handler is already
      # patched by the shim (it's in the known-unshareable skip list → nil
      # in workers). We override the class method to return the per-Ractor
      # handler if set, then fall back to the original (main only) or nil.
      ::ActiveRecord::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def default_connection_handler
          v = ActiveSupport::IsolatedExecutionState[#{dch_key_str}]
          return v unless v.nil?
          if Ractor.main?
            cv = RactorRailsShim::CLASS_ATTR_VALUES[:__ractor_rails_shim_ar_default_connection_handler__]
            return cv if cv
          end
          nil
        end
        def default_connection_handler=(val)
          ActiveSupport::IsolatedExecutionState[#{dch_key_str}] = val
        end
        # Route the per-Ractor handler through Ractor-local storage. IES is
        # per-thread, so a handler stored on the init thread is invisible to the
        # worker's other threads; Ractor.current is per-Ractor and shared by all
        # threads of the worker. Falls back to IES (legacy) then
        # default_connection_handler (main Ractor only).
        def connection_handler
          v = Ractor.current[:active_record_connection_handler]
          return v unless v.nil?
          ActiveSupport::IsolatedExecutionState[:active_record_connection_handler] || default_connection_handler
        end
        def connection_handler=(handler)
          Ractor.current[:active_record_connection_handler] = handler
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
    end

    # Patch ActiveModel::Type::SerializeCastValue::ClassMethods
    # #serialize_cast_value_compatible? to route the lazy class instance
    # variable @serialize_cast_value_compatible through IES.
    #
    # This method lazily caches a boolean: `return @x if defined?(@x); @x =
    # <computation>`. It's called during type-map initialization (every
    # adapter's `initialize_type_map` creates type objects whose constructors
    # eagerly call this to precompute the value). The class instance variable
    # write fails from a non-main Ractor (Ractor::IsolationError: "can not set
    # instance variables of classes/modules by non-main Ractors").
    #
    # Fix: route through IES so each Ractor computes + caches its own value.
    # The computation is deterministic (compares ancestor positions of two
    # methods), so per-Ractor recomputation yields the same result. Each
    # including class gets its own IES key (keyed by `self.name`). String-eval'd
    # (no captured binding), callable from any Ractor.
    def _install_activerecord_serialize_cast_value_patch
      return if @ar_serialize_cast_patched
      @ar_serialize_cast_patched = true
      _register_patch :activerecord_serialize_cast_value, "8.1"
      return unless defined?(::ActiveModel::Type::SerializeCastValue)

      ::ActiveModel::Type::SerializeCastValue::ClassMethods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def serialize_cast_value_compatible?
          key = :"ractor_rails_shim_scv_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          result = ancestors.index(instance_method(:serialize_cast_value).owner) <= ancestors.index(instance_method(:serialize).owner)
          ActiveSupport::IsolatedExecutionState[key] = result
          result
        end
      RUBY
    end

    # Patch ActiveRecord::Delegation.uncacheable_methods to route the lazy
    # class instance variable @uncacheable_methods through IES.
    #
    # `uncacheable_methods` is a class method on the `Delegation` module:
    # `@uncacheable_methods ||= (delegated_classes.flat_map(&:public_instance_methods)
    # - Relation.public_instance_methods).to_set.freeze`. It's read during
    # `method_missing` on relation delegate classes (e.g. when Kaminari calls
    # `Post.page(1).per(10)` — `per` isn't a standard Relation method, so
    # `ClassSpecificRelation#method_missing` checks `uncacheable_methods` to
    # decide whether to delegate). The class instance variable write fails
    # from a non-main Ractor (Ractor::IsolationError).
    #
    # Fix: route through IES so each Ractor computes + caches its own Set.
    # The computation is deterministic (same delegated_classes everywhere).
    # String-eval'd (no captured binding), callable from any Ractor.
    def _install_activerecord_delegation_patch
      return if @ar_delegation_patched
      @ar_delegation_patched = true
      _register_patch :activerecord_delegation, "8.1"
      return unless defined?(::ActiveRecord::Delegation)

      ::ActiveRecord::Delegation.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def uncacheable_methods
          key = :ractor_rails_shim_ar_uncacheable_methods
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          result = (
            delegated_classes.flat_map(&:public_instance_methods) - ActiveRecord::Relation.public_instance_methods
          ).to_set.freeze
          ActiveSupport::IsolatedExecutionState[key] = result
          result
        end
      RUBY
    end

    # Patch ActiveRecord::AttributeMethods::PrimaryKey#primary_key and
    # #composite_primary_key? to not read the PRIMARY_KEY_NOT_SET constant.
    #
    # The original code: `reset_primary_key if PRIMARY_KEY_NOT_SET.equal?(@primary_key)`
    # reads the constant on every call. PRIMARY_KEY_NOT_SET is a BasicObject
    # (can't be frozen, can't be made shareable), so reading the constant from
    # a worker Ractor raises Ractor::IsolationError — even if @primary_key is
    # already set to the real value.
    #
    # Fix: replace the sentinel check with a shareable-snapshot lookup. At
    # _share_model_classes! time, each model's primary_key is warmed in main
    # and stored in AR_PRIMARY_KEYS_SHAREABLE (a frozen Hash). The patched
    # primary_key method checks IES first (per-Ractor), then the shareable
    # snapshot, then falls back to the original logic in the main ractor.
    # Workers never read the constant. String-eval'd (no captured binding).
    def _install_activerecord_primary_key_patch
      return if @ar_primary_key_patched
      @ar_primary_key_patched = true
      _register_patch :activerecord_primary_key, "8.1"
      return unless defined?(::ActiveRecord::AttributeMethods::PrimaryKey::ClassMethods)

      mod = ::ActiveRecord::AttributeMethods::PrimaryKey::ClassMethods
      mod.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def primary_key
          key = :"ractor_rails_shim_pk_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v unless v.nil?
          if Ractor.main?
            reset_primary_key if PRIMARY_KEY_NOT_SET.equal?(@primary_key)
            v = @primary_key
            ActiveSupport::IsolatedExecutionState[key] = v
            v
          else
            RactorRailsShim::AR_PRIMARY_KEYS_SHAREABLE[name]
          end
        end
        def composite_primary_key?
          key = :"ractor_rails_shim_pk_\#{name || object_id}"
          v = ActiveSupport::IsolatedExecutionState[key]
          return v.is_a?(::Array) unless v.nil?
          if Ractor.main?
            reset_primary_key if PRIMARY_KEY_NOT_SET.equal?(@primary_key)
            @primary_key.is_a?(::Array)
          else
            pk = RactorRailsShim::AR_PRIMARY_KEYS_SHAREABLE[name]
            pk.is_a?(::Array)
          end
        end
      RUBY
    end

    # `ActiveRecord::Base#cached_find_by_statement` reads
    # `@find_by_statement_cache[connection.prepared_statements]` (a Hash whose
    # values are `Concurrent::Map`s) and calls `cache.compute_if_absent(key)`.
    # `Concurrent::Map` is unshareable, so `make_app_shareable!` replaces the
    # maps with frozen Hashes whose values end up `nil` — and `Hash` has no
    # `compute_if_absent` anyway. In a worker Ractor this raises
    # `NoMethodError: undefined method 'compute_if_absent' for nil`, breaking
    # `find` / `find_by` / `take` (but not `where`, which doesn't use the
    # cache). Fix: in non-main Ractors, build the per-find-statement cache in
    # `IsolatedExecutionState` (per-Ractor, mutable) keyed by the model class
    # and `connection.prepared_statements`. Main keeps the original
    # `Concurrent::Map`-backed behavior via `super`.
    def _install_activerecord_find_by_cache_patch
      return if @activerecord_find_by_cache_patched
      @activerecord_find_by_cache_patched = true
      _register_patch :activerecord_find_by_cache, "8.1"
      return unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def cached_find_by_statement(connection, key, &block)
          return super if Ractor.main?
          cache = (ActiveSupport::IsolatedExecutionState[:"ractor_rails_shim_find_by_cache_\#{object_id}"] ||= {})
          prepared = connection.prepared_statements
          sub = (cache[prepared] ||= {})
          if sub.key?(key)
            sub[key]
          else
            sub[key] = ::ActiveRecord::StatementCache.create(connection, &block)
          end
        end
      RUBY
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

    # Patch ActiveRecord::QueryLogs#tag_content. It reads the `@handlers` and
    # `@formatter` class ivars (populated from config.active_record.query_log_tags
    # during boot) on every SQL statement, so a worker Ractor raises
    # Ractor::IsolationError. `cached_comment` is a thread_mattr_accessor (already
    # Ractor-safe), so only the handlers/formatter need handling. Capture a
    # shareable snapshot in main (snapshot_query_logs!, post-boot) and have
    # workers build the comment from it — query-log tags then work in workers
    # exactly as in dev's main Ractor.
    def _install_activerecord_query_logs_patch
      return if @query_logs_patched
      @query_logs_patched = true
      _register_patch :query_logs, "8.1"
      return unless defined?(::ActiveRecord::QueryLogs)
      ql = ::ActiveRecord::QueryLogs
      # tag_content is defined as a SINGLETON method on ActiveRecord::QueryLogs
      # (not an instance method), so alias the singleton method (not an
      # instance one) and fall back to it for the main Ractor / when the
      # snapshot is unavailable.
      ql.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        alias_method :__ractors_original_tag_content, :tag_content
        def tag_content(connection)
          return __ractors_original_tag_content(connection) if Ractor.main?
          snap = ::RactorRailsShim::QUERY_LOGS_SNAPSHOT
          return __ractors_original_tag_content(connection) unless snap
          format = snap[:format]
          formatter = case format
            when :sqlcommenter then ::ActiveRecord::QueryLogs::SQLCommenter
            else ::ActiveRecord::QueryLogs::LegacyFormatter
          end
          return nil unless formatter
          context = ActiveSupport::ExecutionContext.to_h
          context[:connection] ||= connection
          pairs = snap[:handlers].filter_map do |(key, kind, data)|
            val = case kind
              when :get_key then context[key]
              when :identity then data
              else nil
            end
            formatter.format(key, val) unless val.nil?
          end
          formatter.join(pairs)
        end
      RUBY
    end

    # Capture the QueryLogs handlers/formatter as a shareable snapshot for
    # workers (called post-boot, main Ractor, in prepare_for_ractors!).
    #
    # We deliberately do NOT use Ractor.make_shareable on the raw `@handlers`
    # objects: a handler may be a ZeroArityHandler wrapping a Proc, a raw
    # lambda/Proc tag, or an IdentityHandler whose value is unshareable — all of
    # which make_shareable raises on, which (the original rescue swallowed) left
    # QUERY_LOGS_SNAPSHOT unset and every worker falling through to the original
    # tag_content -> @handlers read -> Ractor::IsolationError. Instead we build a
    # fresh, guaranteed-shareable structure:
    #   { format: :legacy|:sqlcommenter,
    #     handlers: [[key, :get_key, nil] | [key, :identity, value], ...] }
    # Only GetKeyHandler (context key lookup) and IdentityHandler (constant
    # value, when that value itself is shareable) are captured. Proc/lambda
    # handlers can't be expressed cross-Ractor and are dropped in workers (tags
    # that depend on per-request Procs simply don't appear in worker query
    # comments — acceptable; the main Ractor still logs them).
    def snapshot_query_logs!
      return unless defined?(::ActiveRecord::QueryLogs)
      return if RactorRailsShim.const_defined?(:QUERY_LOGS_SNAPSHOT)
      return unless Ractor.main?
      begin
        ql = ::ActiveRecord::QueryLogs
        format = ql.tags_formatter
        format = :legacy if format == false || format.nil?
        raw_handlers = ql.instance_variable_get(:@handlers) || []
        entries = []
        raw_handlers.each do |key, handler|
          if handler.is_a?(::ActiveRecord::QueryLogs::GetKeyHandler)
            entries << [key, :get_key, nil]
          elsif handler.is_a?(::ActiveRecord::QueryLogs::IdentityHandler)
            value = handler.instance_variable_get(:@value)
            next unless Ractor.shareable?(value)
            entries << [key, :identity, value]
          else
            # ZeroArityHandler (wraps a Proc) or a raw Proc/lambda tag:
            # intrinsically unshareable / depends on a closure; skip in workers.
            next
          end
        end
        snap = { format: format, handlers: entries.freeze }.freeze
        Ractor.make_shareable(snap)
        RactorRailsShim.const_set(:QUERY_LOGS_SNAPSHOT, snap)
      rescue StandardError
        nil
      end
    end

    # Patch ActiveRecord::Migrator.migrations_paths (a singleton attr_accessor
    # reading the `@migrations_paths` class ivar) and
    # ActiveRecord::Migration::CheckPending (the dev pending-migration
    # middleware) to be Ractor-safe. In dev, CheckPending runs on every request
    # and reads Migrator.migrations_paths + mutates its own `@watcher` /
    # `@needs_check` ivars on the (frozen, shared) middleware instance. Route
    # the class ivar and the instance ivars through IsolatedExecutionState so
    # each worker reads the main Ractor's migrations paths and builds its own
    # watcher. This keeps the dev pending-migration guard working under kino
    # :ractor instead of stripping the middleware.
    def _install_activerecord_migration_patch
      return if @activerecord_migration_patched
      @activerecord_migration_patched = true
      _register_patch :activerecord_migration, "8.1"
      return unless defined?(::ActiveRecord::Migrator)

      mig = ::ActiveRecord::Migrator
      mp_key = :ractor_rails_shim_migrator_migrations_paths
      mp_key_str = mp_key.inspect
      mig.singleton_class.module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def migrations_paths
          v = ActiveSupport::IsolatedExecutionState[#{mp_key_str}]
          return v unless v.nil?
          if Ractor.main? && instance_variable_defined?(:@migrations_paths)
            v = @migrations_paths
            ActiveSupport::IsolatedExecutionState[#{mp_key_str}] = v
            v
          else
            ["db/migrate"].freeze
          end
        end
        def migrations_paths=(val)
          ActiveSupport::IsolatedExecutionState[#{mp_key_str}] = val
          @migrations_paths = val if Ractor.main?
          val
        end
      RUBY

      return unless defined?(::ActiveRecord::Migration::CheckPending)
      cp = ::ActiveRecord::Migration::CheckPending
      w_key = :ractor_rails_shim_check_pending_watcher
      nc_key = :ractor_rails_shim_check_pending_needs_check
      w_key_str = w_key.inspect
      nc_key_str = nc_key.inspect
      cp.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def call(env)
          @mutex.synchronize do
            watcher = ActiveSupport::IsolatedExecutionState[#{w_key_str}]
            if watcher.nil?
              watcher = ActiveSupport::IsolatedExecutionState[#{w_key_str}] = build_watcher do
                ActiveSupport::IsolatedExecutionState[#{nc_key_str}] = true
                ::ActiveRecord::Migration.check_pending_migrations
                ActiveSupport::IsolatedExecutionState[#{nc_key_str}] = false
              end
            end
            needs_check = ActiveSupport::IsolatedExecutionState[#{nc_key_str}]
            needs_check = true if needs_check.nil?
            if needs_check
              watcher.execute
            else
              watcher.execute_if_updated
            end
          end
          @app.call(env)
        end
      RUBY
    end

    # In the shared :ractor graph, ActiveRecord model classes can end up with a
    # nil `__callbacks` (the class_attribute value can't be made shareable when
    # it holds unshareable callback Procs, so the shim's shareable fallback
    # returns nil). `has_transactional_callbacks?` calls the generated
    # `_rollback_callbacks` / `_commit_callbacks` / `_before_commit_callbacks`
    # readers, which do `__callbacks[:kind]` directly — bypassing the
    # `run_callbacks_with_nil_safe` guard. With a nil `__callbacks` that raises
    # `NoMethodError: undefined method '[]' for nil`, breaking every
    # `save` / `update` / `destroy` (they run inside a transaction). Guard it:
    # a nil / empty callback table means no transactional callbacks.
    def _install_activerecord_transaction_callbacks_patch
      return if @activerecord_transaction_callbacks_patched
      @activerecord_transaction_callbacks_patched = true
      _register_patch :activerecord_transaction_callbacks, "8.1"
      return unless defined?(::ActiveRecord::Base)
      ar = ::ActiveRecord::Base
      ar.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def has_transactional_callbacks?
          cb = __callbacks
          return false unless cb
          !((cb[:rollback] || []).empty?) ||
            !((cb[:commit] || []).empty?) ||
            !((cb[:before_commit] || []).empty?)
        end
      RUBY
    end
  end
end
