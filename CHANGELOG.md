# Changelog

All notable changes to ractor-rails-shim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0]

### Changed — breaking (public API)
- **`worker_app` renamed to `worker_app!`.** The factory freezes +
  `Ractor.make_shareable`s the `WorkerApp` — a destructive build — so it
  now carries the bang the naming convention reserves for "mutates /
  produces a frozen shareable." Callers following the README's
  `Ractor.new(worker_app) { |a| a.call(env) }` example must update to
  `worker_app!`. The old name is gone. (`patches/core.rb`)

- **`fix_url_helpers_singleton_routes` renamed to
  `fix_url_helpers_singleton_routes!`.** Mutates the global routes
  singleton; now bang-suffixed per the convention documented at the top
  of `patches.rb`. (`patches/route_helpers.rb`)

- **Tightened `activesupport` dependency to `>= 8.1`.** The gemspec
  previously declared `>= 7.0`, but the shim only supports Rails 8.1
  (per `Version::TESTED_RAILS` / `SUPPORTED_RAILS`). The looser bound let
  Bundler resolve against AS 7.x where the class-layout patches
  (`class_attribute`, `Callbacks`, `PathRegistry`, …) would silently miss
  blockers or redefine the wrong methods. Bound at `>= 8.1` so Bundler
  fails fast on an unsupported Rails. (`ractor-rails-shim.gemspec`)

### Fixed
- **`_apply_shareable_constants!` set the done-flag on undefined
  constants.** It set `@shareable_constants_done = true` after the first
  run unconditionally, even when registered constants didn't exist yet
  (`make_constant_shareable` returned `false`). A later call (from
  `make_app_shareable!` or `prepare_for_ractors!`) short-circuited on the
  flag and never retried the now-loadable constants — workers then hit
  `Ractor::IsolationError` on unshareable values (e.g.
  `Rack::Utils::PATH_SEPS`, a Regexp not deep-frozen until
  `make_shareable` runs on it). The flag now sets only when every
  registered constant was made shareable; any `false` return leaves it
  unset so the next call retries. Caught by the integration spec (boots
  a real Rails 8.1 app, dispatches `GET /up` in a worker Ractor); pinned
  by `apply_shareable_constants_retry_spec.rb`.

- **ActionFilter private ivar reads now gated through the `_swallow`
  debug funnel.** The eval'd `set_callback` interceptor inlined
  `af.instance_variable_get(:@conditional_key) rescue nil`, but
  `instance_variable_get` returns nil for a missing ivar *without*
  raising — the rescue never fired, and a silent Rails internal rename
  (`@conditional_key` / `@actions`) would leave `only`/`except` nil,
  making callbacks run for actions they shouldn't (security-relevant)
  with no visible cause. New `_read_action_filter_constraints(af)` checks
  `instance_variable_defined?` and emits a labeled
  `[ractor_rails_shim] action filter constraints: missing ivar …`
  warning under `debug=true`. Returns `[nil, nil]` for a bare object,
  `[key, symbols]` when the ivars are present.

- **Dead ternary in thread-mode `class_attribute` reader.** The reader
  carried `:__class_attr___callbacks == :__callbacks ? {} : nil`, but
  the namespaced name is always `__class_attr_<name>` (never `<name>`),
  so the check was always false — dead code that allocated a `Symbol`
  via `inspect` on every read AND never delivered the intended `{}`
  default for `__callbacks` (callers index the result, so `nil` would
  `NoMethodError`). Replaced with a static decision based on the public
  name, inlining the shared frozen `EMPTY_CALLBACKS_HASH` constant.

- **Redundant `class_variable_set` pair in `mattr_accessor` writer.**
  The shim-generated writer had two complementary guarded lines
  (`set if defined?` + `set unless defined?`) that together were one
  unconditional set, with a wasted `class_variable_defined?` per write.
  Replaced with a single `class_variable_set(cv, val) if Ractor.main?`.

- **`WorkerApp#setup_once!` race-spec cleanup leak.** The race spec's
  `ensure` block restored `Thread::Mutex.new` via
  `define_method { orig_new.call }`, leaving a block that captures a
  main-Ractor-bound `Method`. When a later spec's worker Ractor called
  `Thread::Mutex.new` it raised `IsolationError` (flaky
  `WorkerAppSpec#test_0002`). Replaced with `remove_method(:new)` so the
  call falls back to the class-defined `new` (no captured binding).

### Changed
- **Centralized `const_set`-with-suppressed-`$VERBOSE` into
  `_reassign_shareable_const(name, value)`.** `SHAREABLE_FALLBACK`,
  `SHAREABLE_MATTR_DEFAULTS`, `SHAREABLE_APP`, and
  `SHAREABLE_DECLARED_CALLBACKS` were each rebuilt + reassigned via an
  inlined `$VERBOSE = nil … const_set … ensure $VERBOSE = …` dance. The
  dance now lives in one helper on `RactorRailsShim`; all rebuild sites
  (including the 6 `activerecord.rb` sites + 1 `kaminari.rb` site) call
  it. The constants stay frozen shareable `Hash`es (always readable from
  any Ractor) — a mutable-then-frozen registry would not be shareable
  until `freeze!`, breaking workers that read early.

- **Callable/lock object model extracted to `patches/callables.rb`.**
  `NoOpProc` / `Callable` / `CallableConst` / `DeviseMappingSnapshot` /
  `NoOpLock` / `NoOpLogDev` + the `_devise_mapping_snapshot` helper moved
  out of the 964-line `make_shareable.rb` into their own file. Plain
  class definitions replace the string-eval indirection (the eval was
  stylistic, not behavioral). `make_shareable.rb`: 964 → 822 lines.

- **`VersionPolicy` module extracted from the `RactorRailsShim` god
  module.** The version-policy + patch-registry concern (`:warn` /
  `:strict` / `:off` switch, `PATCH_VERSIONS`, `_register_patch` /
  `applicable_patches` / `_version_mismatch`) moved from the
  `RactorRailsShim` singleton in `core.rb` to
  `RactorRailsShim::VersionPolicy` (`version_policy.rb`). `core.rb` keeps
  the public facade (`RactorRailsShim.version_policy`, `.applicable_patches`,
  `::PATCH_VERSIONS`, `::UnsupportedVersionError`) delegating to the
  module. Orthogonal to the already-extracted `RactorRailsShim::Version`
  (detection).

- **`mattr_accessor` split into single-responsibility helpers.** The
  per-symbol body did four things (call super, push to `CLASS_ATTRIBUTES`,
  seed the default + rebuild the shareable constant, redefine the
  reader/writer). Extracted `_seed_mattr_default(key, default)` and
  `_register_for_fallback(mod_name, sym, key, default)`; `mattr_accessor`
  now reads `super, register, seed, redefine`.

- **Thread-mode vs Ractor-mode `class_attribute` heredocs de-duplicated.**
  Each branch inlined a near-identical ~25-line reader/writer heredoc,
  differing only in the method name. Extracted
  `_class_attr_thread_methods` / `_class_attr_ractor_methods` (each builds
  one reader+writer pair); `redefine` calls the helper twice. One source
  of truth per mode. Also fixed a misaligned `else` (12-space indent in a
  10-space block). `class_attribute.rb`: 232 → 224 lines.

- **Freeze-path bare rescues routed through the `_swallow` debug funnel.**
  `_freeze_shareable_class_ivars!`, `_freeze_declared_callbacks!`,
  `_collect_controller_classes`, `_replace_locks_and_concurrent_maps!`,
  `_replace_one_proc`, `_neutralize_logger_io!`,
  `DeviseMappingSnapshot`, `_devise_mapping_snapshot`, `_warm_journey_routes`,
  url-helper freeze, `DUMMY_END_NODE`, `MimeNegotiation`, AR db-config
  handlers, AR query transformers, devise mappings, and the view-context
  fallback now emit a labeled `[ractor_rails_shim] <label>: …` line to
  `$stderr` under `debug=true` instead of bare `rescue; nil`. Silent by
  default (backward compatible).

- **`fallback_ies.rb` moved into the `RactorRailsShim` namespace.** It
  previously defined `ActiveSupport::IsolatedExecutionState` directly
  inside the `ActiveSupport` namespace (guarded by `defined?`). Defining
  an upstream-namespaced constant from a third-party gem is a
  namespace-patch smell — if a future AS lazy-loads IES, load order
  decides which definition wins. The fallback now lives at
  `RactorRailsShim::FallbackIES` and is aliased onto
  `ActiveSupport::IsolatedExecutionState` only when the real AS IES is
  absent. The ~270 string-eval'd references across the patch files
  resolve to the alias when AS is absent and to the real one when present.

- **Stream-of-consciousness comments trimmed to one-line invariants.**
  Working-notes-style comments that narrated history ("actually it IS a
  constant holding…", "Pre-fix the traversals only handled…") replaced
  with one-line invariant statements. The history is in git.

### Documentation
- **`WorkerApp#setup_once!` race comment corrected (again).** A prior
  0.2.6 entry claimed `Ractor.current[:key] ||= Thread::Mutex.new` is
  atomic in Ruby 4.0.6. It is NOT — `||=` is a read-then-write, and N
  racing threads produce N distinct mutexes (verified by spec under a
  widened window). The code is saved by (1) MRI's GIL serializing the
  flag check inside `synchronize` and (2) `rebind_constants` /
  `init_worker_ar_connections!` both being idempotent. Comment now states
  the real contract + the escape hatch if either property changes. Two
  specs pin the idempotency contract.

## [0.2.6]

### Fixed
- **`WorkerApp` from `worker_app` not `Ractor.shareable?`.** The factory
  returned a bare `WorkerApp` instance without freezing or making it
  shareable, so any caller following the README's
  `Ractor.new(worker_app) { |a| a.call(env) }` example would raise
  `Ractor::IsolationError` at spawn. `worker_app` now freezes +
  `Ractor.make_shareable`s the instance, enforcing the shareability
  contract at the boundary instead of pushing it onto every caller.
  (`patches/core.rb`)

- **`Hash#compute_if_absent` nil-caching divergence from
  `Concurrent::Map`.** The shim replaces `Concurrent::Map` instances in
  the frozen app graph with plain `Hash`es (Concurrent::Map isn't
  Ractor-shareable) and adds a compatible `compute_if_absent`. The
  frozen-Hash branch used `IES[key] ||= yield`, which SKIPS nil results
  — but `Concurrent::Map#compute_if_absent` STORES nil (verified: the
  key is present after a nil-result block call), so the shim's
  divergent semantics re-invoked the block on every subsequent lookup
  for any cache slot whose computed value was nil. The frozen branch
  now uses a two-level IES bucket (`slot[object_id][key]`) with a
  proper `key?` presence check, matching `Concurrent::Map` exactly.
  Also fixed: an existing key on a frozen Hash now returns without
  invoking the block (was always treating the receiver as empty), and
  per-Hash isolation is now keyed by `object_id` so two frozen hashes
  with the same key don't collide. (`patches/core.rb`)

- **Magic `line == 32` strategy dispatch replaced with identity check.**
  The Proc-replacement pass distinguished
  `ActionDispatch::Routing::Mapper::Constraints::SERVE` from `CALL` by
  hard-coding the `source_location` line number (32). Any Rails patch
  release that shifted the constant definitions by even one line would
  silently swap the two strategies and break routing (a dispatcher
  endpoint called as `app.call(req.env)` instead of `app.serve(req)`).
  Replaced with an `equal?` check against the actual constants — the
  value stored in `@strategy` IS the constant object (Rails assigns it
  by reference), so identity is the robust identifier, independent of
  source layout. Falls through to `NoOpProc` for an unknown Proc
  (defensive; never mis-routes). Extracted into
  `_strategy_replacement_for`. (`patches/make_shareable.rb`)

- **`capture_app_constants` crash on non-Zeitwerk autoloaders.** The
  method called `Rails.autoloaders.main` / `.once` directly, which
  `NoMethodError`s for apps in classic-loader mode or with
  `config.autoloaders = false` (the autoloaders object exists but
  doesn't expose `main`/`once`). Now filters to the loaders that
  actually expose `all_expected_cpaths` (the Zeitwerk introspection
  API), and tolerates autoloaders objects that only respond to `each`.
  Also fixed a pre-existing bug: the early-return path returned an
  UNFROZEN map, violating the method's documented frozen-map contract.
  (`patches/core.rb`)

### Changed
- **`_replace_unshareable_procs!` 3.times magic replaced with a
  fixed-point loop.** The original `3.times` had no justification and
  an arbitrary constant. Replaced with a loop-to-fixed-point (break
  when `_collect_procs` returns empty) plus a safety cap of 8 passes
  to guard against a pathological graph where replacement keeps
  introducing new Procs (the replacements are `NoOpProc`/`Callable`,
  not `Proc`, so this shouldn't happen, but the cap prevents an
  infinite loop). Documented the multi-occurrence rationale (the same
  Proc object can live in many containers, e.g. shared deprecation
  behaviors). Observed real graphs converge in 2 passes.
  (`patches/make_shareable.rb`)

- **Graph traversals now walk Set/Struct/Enumerable.**
  `_collect_procs` and `_replace_locks_and_concurrent_maps!` only
  handled `Array` and `Hash` as recursive containers. Rails uses `Set`
  in several caches (e.g. `ActionDispatch::Journey::Routes`), and
  `Struct`/`Enumerable` mixes appear in framework internals — a
  `Mutex` or `Proc` nested inside one of those was missed and left
  unshareable, breaking `make_app_shareable!` downstream. Extracted
  `_each_ivar_and_child` (single responsibility: enumerate every child
  reference of an object) shared by both traversals, handling `Hash`,
  `Array`, `Set`, `Struct`, and a generic `Enumerable` fallback
  (`Range`, `Enumerator`, custom mixins). The `Hash#default_proc`
  branch is preserved so `_collect_procs` still flags default-proc
  Procs. (`patches/make_shareable.rb`)

### Added
- **Debug funnel for freeze-path silent rescues.** The
  freeze/shareability paths (`_freeze_active_record_class_ivars!`,
  `_freeze_global_class_ivars!`, `_make_value_shareable`) rescue all
  exceptions silently with bare `rescue; nil`. Individual failures are
  expected (some ivars hold intrinsically unshareable values like
  Procs), but a worker Ractor that later crashes on the same
  unshareable value had no traceable cause. New `_swallow(label) { ... }`
  funnel is silent by default (preserves backward compat) and emits a
  labeled `[ractor_rails_shim] <label>: <class>: <msg>` line to
  `$stderr` when `RactorRailsShim.debug = true`. The three freeze-path
  rescues are routed through it; the bare rescues in non-freeze paths
  (require `LoadError`, optional `const_get`, etc.) are left as-is —
  those are genuinely expected and a `$stderr` line would be noise.
  (`patches/core.rb`)

### Documentation
- **`WorkerApp#setup_once!` race comment corrected.** The previous
  comment claimed `Ractor.current[:key] ||= Thread::Mutex.new` was racy
  under "extreme contention" and dismissed it as harmless because the
  init steps are idempotent. Verified on Ruby 4.0.6 that
  `Ractor.current[:key] ||= X` is atomic (100 concurrent threads
  produce exactly one mutex object), so the TOCTOU race does not
  occur. Replaced the misleading comment with the verified finding.

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
