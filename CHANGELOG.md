# Changelog

All notable changes to ractor-rails-shim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.5]

### Fixed
- **Nil-sentinel storage bug in IES-routed accessors.** The shim's
  `mattr_accessor` / `class_attribute` / Rails-module / AR / Rack / Devise /
  Kaminari / I18n / Inflector / ActionView / ActionController /
  ActionDispatch / Zeitwerk / ExecutionWrapper readers used
  `return v unless v.nil?` to detect "no per-Ractor override has been set."
  That made `Foo.x = nil` (or `= false`) indistinguishable from "never set,"
  so the reader silently fell through to the default/fallback instead of the
  user's explicit `nil`/`false` — a divergence from threaded Rails, where
  class variables distinguish "undefined" (`class_variable_defined?` is
  false) from "set to nil." Replaced the nil-sentinel with `<storage>.key?`
  at every IES / `CLASS_ATTR_VALUES` / `SHAREABLE_FALLBACK` reader so any
  explicit assignment — including `nil` and `false` — wins over the
  fallback. The single `Ractor.current[:active_record_connection_handler]`
  reader keeps the nil-sentinel (with an explanatory comment) because
  `Ractor#[]` has no `key?` method and `connection_handler=` is never called
  with nil in practice. 58 sites transformed across 13 patch files.
  Regression specs in `spec/sentinel_spec.rb` cover the
  `mattr_accessor :flag, default: true; Flag = nil; Flag # => nil` and
  `class_attribute :setting, default: :on; Setting = nil; Setting # => nil`
  cases.

- **`Ractor::IsolationError` in worker schema reload.** When a worker Ractor
  hit a cold schema (e.g. first request after boot, or after
  `ActiveRecord::Base.connection_handler.clear_all_connections!`),
  `ModelSchema::ClassMethods#reload_schema_from_cache` and
  `Timestamp::ClassMethods#reload_schema_from_cache` wrote to class instance
  variables (`@columns`, `@columns_hash`, …) on the shared model classes,
  raising `Ractor::IsolationError: can not set instance variables of
  classes/modules by non-main Ractors`. Patched both methods (plus
  `AttributeRegistration::ClassMethods#reset_default_attributes!`) to clear
  the worker's IES slots instead of writing class ivars, so the next read
  re-derives the schema in the worker's own IES. Without this, any worker
  that reloaded its schema crashed the first request after the reload.

## [0.2.4]

### Performance
- **class_attribute reader (ractor mode) is now allocation-free.** The
  generated `__class_attr_*` accessors previously walked `self.ancestors` and
  built a fresh `Symbol` via string interpolation for *every* ancestor on
  *every* read — the dominant allocation source for GET requests (a Rails class
  has 20–40 ancestors, and class_attribute is read constantly: controller
  filters, view partial paths, AR `strict_loading`, form builder, logger, …).
  In ractor mode the writer already collapses every write to the defining
  owner's single key, so the ancestor walk was dead code. The reader now does a
  single literal-symbol lookup against `IsolatedExecutionState[key]` then
  `SHAREABLE_FALLBACK[key]`, eliminating the per-read `Array` + `Symbol`
  churn. This cuts request allocations substantially and, with them, the
  garbage-collection share of CPU time (was ~33% of CPU on `GET /posts`).

## [0.2.3]

### Fixed
- **Cold `GET /up` `SystemStackError` in worker Ractors (kino `:ractor`).**
  Rails' `ActionDispatch::Routing::RouteSet#generate_url_helpers` builds a
  module whose `self.included(base)` hook re-dups the module and re-includes
  it while `!base._routes.equal?(@_proxy._routes)`. Under the frozen,
  Ractor-shareable app graph a worker Ractor's controller reports
  `base._routes` as `nil`, so the equality never holds and the hook
  re-includes forever (empty Ruby backtrace, first request only; respawns and
  later requests are fine). The shim's `route_helpers.rb` `generate_url_helpers`
  override now bounds the reinclude to once per base, preserving the
  route-alignment intent without the infinite loop. Verified: cold `GET /up`
  returns 200 in `kino -m ractor`; both `:ractor` and `:threaded` modes clean.

## [0.2.2]

### Fixed
- **Multi-threaded worker race in `WorkerApp#setup_once!` (kino `:ractor`,
  `-wN -tM` with M > 1).** All threads inside a worker Ractor share
  `Ractor.current`, so the previous `Ractor.current[:rrs_worker_ready]` guard
  let multiple threads race through `rebind_constants` +
  `init_worker_ar_connections!`, producing
  `ActiveRecord::ConnectionNotEstablished` on the very first request. Setup is
  now serialized with a per-Ractor `Thread::Mutex`, and `rebind_constants`
  re-fetches each namespace parent so concurrent setup cannot clobber a module
  out from under another thread.
- **Per-thread ActiveRecord connection handler (intermittent
  `ConnectionNotEstablished` on `kino :ractor -w5 -t5`).** `init_worker_ar_connections!`
  stored the per-Ractor `ConnectionHandler` in `ActiveSupport::IsolatedExecutionState`,
  which is **per-thread** (`Thread.attr_accessor`). The init thread set it, but
  the other worker threads in the same Ractor saw `nil` →
  `ConnectionNotEstablished: No connection handler for Ractor X` on a fraction of
  requests. The handler now lives in `Ractor.current` (per-Ractor, shared by all
  of the worker's threads), and `ActiveRecord::Base.connection_handler` reads it
  there first.
- **Write-path `Ractor::IsolationError` on `redirect_to @post`
  (`kino :ractor -w5 -t5`, `POST /posts`).** `ActiveModel::AttributeMethods::
  ClassMethods#attribute_method_patterns_cache` stored a mutable `Concurrent::Map`
  in a class instance variable (unshareable). Hit via `redirect_to @post` →
  `respond_to?` → `matched_attribute_method`, raising from worker Ractors. The
  cache is now routed through `Ractor.current` (per-Ractor, keyed per class) and
  populated lazily per Ractor — content is deterministic, so per-Ractor
  recomputation is correct.

  With these three fixes, `kino :ractor (-w5 -t5)` serves `/up`, `GET /posts`,
  and `POST /posts` (authenticated write + 302) with 0 transport failures and 0
  server errors under sustained load.

### Added — ActiveRecord query-path ractor-safety (Blocker 1 deep work)
- `RactorRailsShim.worker_ar_init(app)` — a shareable Rack middleware that
  calls `init_worker_ar_connections!` on each worker's first request. Kino's
  `:ractor` mode has no worker-init hook, so `config_ractor.ru` (generated by
  `make_full_test_app.sh`) now wraps the shareable app with it.
- `_share_relation_delegate_caches!` — deep-freezes each AR model class's
  `@relation_delegate_cache` (mutable Hash of shareable delegate Classes) so a
  worker Ractor can read it. (`patches/activerecord.rb`)
- `_share_model_classes!` — warms every AR model class in main (runs
  `count`/`first`/`page`/`table_name`/...) to populate lazy `@ivar ||= ...`
  class ivars, then makes each shareable (deep-freeze; Monitor/Mutex→
  `NoOpLock`; `Concurrent::Map`→frozen Hash; unfreezable caches→frozen empty
  container). Fixes `@table_name`, `@arel_table`, `@predicate_builder`, etc.
- `_share_active_record_internals!` — warms `.empty` + freezes class ivars on
  the AR `*Clause` helper classes (`WhereClause`, `FromClause`).
- `_install_activerecord_configurations_patch` — routes the raw
  `@@configurations` class var (`ActiveRecord::Base.configurations`) through
  IES with a shareable deep-frozen `DatabaseConfigurations` fallback.
- ~30 non-shareable AR/Arel constants registered in `SHAREABLE_CONSTANTS`
  (`VALID_UNSCOPING_VALUES`, `MULTI_VALUE_METHODS`, `STRING_OR_SYMBOL_CLASS`,
  `NATIVE_DATABASE_TYPES`, ...). `make_constant_shareable` now special-cases
  Monitor/Mutex constants → `NoOpLock` and rescues intrinsically-unshareable
  values (Proc / `Concurrent::Map` / `TypeMap`) instead of crashing.
- `_capture_ar_configurations!` now reads
  `Rails.application.config.database_configuration` (`DatabaseConfigurations`
  has no `#each` in this Rails/Ruby).
- `verify_blockers.rb` (generated by `make_full_test_app.sh`) — end-to-end
  data-layer + HTTP-dispatch check in a worker Ractor.

### Known limitations (DB queries from worker Ractors)
- `Post.count` / `Post.page(1)` from a worker Ractor still fail at
  `ActiveRecord::DatabaseConfigurations.db_config_handlers` (an Array of
  **Procs** registered by adapters), and downstream at the SQLite
  `TYPE_MAP` (Procs) and `QUOTED_*` `Concurrent::Map` quoting caches.
  These are intrinsically unshareable and require upstream Rails changes
  (shareable callables instead of Procs; per-Ractor quoting caches). See
  the "deep AR ractor-unsafety" wall in the project notes.

## [0.2.0] - 2026-07-09

### Added — productionization (Phase 6)
- **Version detection infrastructure.** New `RactorRailsShim::Version` module
  with `Gem::Version`-based runtime checks (`ruby`, `rails`, `rails_segment`,
  `supported_ruby?`, `supported_rails?`, `satisfies?`). Replaces the string-
  prefix compare so pre-release and patch versions sort correctly.
  (`lib/ractor_rails_shim/version_check.rb`)
- **Version policy switch.** `RactorRailsShim.version_policy = :warn | :strict |
  :off`. The default `:warn` preserves backward compatibility; `:strict`
  raises `RactorRailsShim::UnsupportedVersionError` on untested Rails/Ruby;
  `:off` silences. (`patches.rb`)
- **Patch version registry.** Every `install_*` / `_install_*` method registers
  its tested Rails versions in `RactorRailsShim::PATCH_VERSIONS`. Use
  `RactorRailsShim.applicable_patches` to see which patches applied to the
  runtime (and which were skipped as untested). This is the "load different
  patches for different Rails versions" extension point — to add 7.x support,
  write version-specific variants and tag them in the registry.
  (`patches.rb`)
- **CI.** GitHub Actions workflow (`.github/workflows/ci.yml`): a fast unit
  job (no Rails) plus an integration job that builds the minimal Rails 8.1
  test app, makes it shareable, and dispatches `GET /up` in a worker Ractor —
  asserting HTTP 200. Also runs `ractor-rails-check` against the test app.
- **Unit specs** for the version infrastructure and the callable/lock
  replacement classes (`NoOpProc`, `Callable`, `CallableConst`,
  `RequestCallable`, `NoOpLock`, `NoOpLogDev`) — including cross-Ractor
  callability. (`spec/version_spec.rb`; 31 specs total, up from 8.)
- **CHANGELOG.md.**

### Changed
- `ractor-rails-shim.gemspec`: real metadata (`changelog_uri`,
  `bug_tracker_uri`, `rubygems_mfa_required`), canonical repo URL, CHANGELOG
  included in the gem package.
- `script/make_test_app.sh`: portable `sed` (was macOS-only `sed -i ''`,
  failed on Linux CI).
- Bumped version `0.1.0` → `0.2.0`.

### Fixed
- `.gitignore`: corrected `racker-rails-shim-*.gem` typo to
  `ractor-rails-shim-*.gem`.

## [0.1.0] - 2026-07-09

### Added
- Initial proof-of-concept. Reroutes Rails class-level instance variables
  (`Rails.application`, `Rails.cache`, `Rails.logger`, `mattr_accessor`,
  `class_attribute`, `Zeitwerk::Registry`, unshareable constants) through
  `IsolatedExecutionState` / `Ractor.make_shareable`.
- `make_app_shareable!` — replaces self-capturing Procs with callable objects,
  Mutex/Monitor with no-op locks, `Concurrent::Map` with frozen Hashes, then
  `Ractor.make_shareable(app)`. A worker Ractor dispatches `GET /up` → 200.
- `ractor-rails-check` CLI audit tool.
- Minimal unit specs (8) + an integration spec (self-skips without a test app).
- `VALIDATION.md`, `README.md`.
