# Changelog

All notable changes to ractor-rails-shim are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — production-gem coverage for the reference Gemfile (`Gemfile.test_project`)

Every production gem in the reference Gemfile now has a Ractor verdict, and
the ones with Ractor-hostile state have targeted patches
(`lib/ractor_rails_shim/patches/`, wired through `loader.rb`):

- **faraday** — worker header keys map through a pure per-Ractor cache (the
  upstream `KeyMap` constant holds a Hash-with-default-Proc + captured
  Mutex); middleware/adapter registries captured at boot and promoted
  per-Ractor (every module extending `Faraday::MiddlewareRegistry`, not just
  Middleware/Adapter — a default-stack `Faraday.new` resolves
  `:url_encoded` on `Faraday::Request`); `Middleware.default_options`,
  `Env.member_set` and the `Utils` memos are per-Ractor (redefined on the
  singleton class — the module is `module_function`); a worker branch for
  `default_connection_options`; `NO_ARGUMENT`/`default_adapter_options`
  frozen; `Handler#klass` uses plain `const_get` off-main.
- **json-schema** — the heaviest hand-written class-variable surface in the
  set: `@@mutex` skipped off-main (class-variable reads are forbidden in
  workers entirely, so workers lock-free build their per-instance schema
  state), `@@default_opts` frozen (dup-merged per validation), `@@schemas`
  cached per-Ractor, the draft validators captured frozen, and the Proc
  cvars (`@@serializer`, `@@fake_uuid_generator`) +
  `@@json_backend`/`@@schema_reader` re-built Ractor-locally;
  `@@use_multi_json` snapshotted (frozen `JSON_USE_MULTI_JSON`,
  `multi_json_deprecation_warning!` worker-safe); `TYPE_CLASS_MAPPINGS` and
  the RFC4122 Nil UUID frozen for the validate/`fake_uuid` paths.
- **rack-attack** — module state (configuration/cache/discriminator
  normalizer) served per-Ractor; `BaseProxy.@@proxies` snapshotted into the
  frozen `RACK_ATTACK_PROXIES` constant with a worker branch on `proxies`
  (class-variable reads are forbidden off-main even when the value is
  shareable — freezing in place is not enough); worker-safe
  `Cache.default_store` (`::Object.const_get` — bare `Rails` does not
  resolve in eval'd worker code); real default-responder lambdas per worker,
  including the `retry-after` throttle-header path; the middleware `#call`
  resolves the configuration through the module accessor off-main.
  Limitation documented: DSL check blocks are main-Ractor Procs — re-arm
  them per worker via the new `RactorRailsShim.on_worker_boot` hook.
- **on_worker_boot hook** (`WorkerApp#setup_once!` + `Registry`): register
  blocks (shareable block form, or an always-safe Ruby source string) that
  run once per worker Ractor to re-arm state that cannot cross the
  boundary.
- **jbuilder** — frozen `template_lookup_options`, sentinel-default
  `Jbuilder.new` (no cvar reads off-main), boot DSL captured and replayed
  per worker (jbuilder 2.15+ inherits BasicObject).
- **simple_form** — per-Ractor `discovery_cache`, frozen `@@wrappers`
  snapshot, Ractor-local lambdas for the Proc-valued `label_text` /
  `field_error_proc` mattrs.
- **fast_jsonapi** — frozen capture of each serializer class's 12-piece
  serialization metadata; un-freezable attribute procs degrade to nil.
- **sprockets-rails** — frozen manifest snapshot (`#assets`/`#files`) served
  to worker views, fresh `precompiled_asset_checker`, manifest-only asset
  resolution off-main.
- **telegram-bot** — per-Ractor `Client`s from a frozen `bots_config`;
  worker-safe `default_async_job` (no runtime `const_set`);
  `UpdatesPoller` registry Ractor-local.
- **mailgun-ruby** — the eight module config ivars frozen in place at
  freeze time via `SHAREABLE_CLASS_IVARS` (accessors unchanged).
- **prawn** — per-Ractor AFM font-data cache, metrics path, and
  `Repeater.count`; `image_handler`/`Document.extensions` frozen in place.
- **async-http** — the six runtime-read constants deep-frozen.
- **translit** — the Russian conversion map pre-warmed + frozen.
- **unicode_normalize (stdlib)** — `String#unicode_normalize` crashes in
  workers out of the box (the `Regexp.compile` regexps are unfrozen, and
  `NF_HASH_C`/`NF_HASH_D` are default-proc Hashes the stdlib mutates, so
  they cannot be frozen). Regexps + `UNICODE_ENCODINGS` frozen in place;
  `normalize`/`normalized?` get worker branches that gsub/scan with blocks
  (per-Ractor memo Hashes in the shim storage, `MAX_HASH_LENGTH` cap
  preserved); main keeps the upstream memoizing hashes verbatim. Any code
  path that normalizes user input in a worker (Addressable URI handling,
  transliteration, …) benefits.

Audit results for the remaining gems are recorded in COMPATIBILITY.md
("Test project coverage"): devise, devise-jwt, mission_control-jobs,
redcarpet, pg, bcrypt, the net-* protocol gems, and the asset-pipeline gems
need no patch; activeadmin, aws-sdk-s3, ferrum, and sitemap_generator are
design-incompatible with a frozen shared app and belong in a separate
process.

### Fixed — real-gem worker smoke round (`smoke_worker_fixes_spec.rb`)

The unit suites passed while the real gems still died in worker Ractors;
running the patches against the actual gems surfaced five worker-only crash
paths that no no-gem spec could reach. All replayed as specs next to the
fixes (`spec/smoke_worker_fixes_spec.rb`):

- **rack-attack** — `BaseProxy.proxies` read `@@proxies` in workers
  (`Ractor::IsolationError`; freezing the value does not help — cvar reads
  are forbidden off-main regardless of shareability). Fixed via the
  `RACK_ATTACK_PROXIES` snapshot + worker branch described above; main's
  own `@@proxies` stays mutable so late-registered proxies still register.
- **rack-attack** — the worker `set_defaults` `throttled_responder` was a
  placeholder lambda with no body; workers now build the real upstream
  responder (429 + `Retry later`, optional `retry-after` header from
  `rack.attack.match_data`).
- **json-schema** — worker `initialize` called a never-defined
  `_shim_lock` helper; the worker branch now builds its per-instance
  schema state without a lock (main keeps `@@mutex`).
- **faraday** — the `Utils` memo redefinitions landed as plain instance
  methods on a `module_function` module, so the callable singleton copies
  kept the upstream `@ivar ||=` bodies and workers died setting the module
  ivar; the redefinitions now target `Faraday::Utils.singleton_class`.
- **faraday** — `default_connection_options` memoized into a module ivar
  off-main on the first `Faraday.new`; workers get a per-Ractor
  ConnectionOptions instead.
- **faraday** — the middleware-registry snapshot only captured
  `Faraday::Middleware`/`Faraday::Adapter`; a default-stack
  `Faraday.new` (no block) needs `Faraday::Request`'s `:url_encoded`
  registration off-main. The snapshot now walks every module extending
  `MiddlewareRegistry` via `ObjectSpace`.
- **version-policy specs** — `version_policy_spec` / `version_spec` called
  `PATCH_VERSIONS.clear` on the shared global registry, wiping entries
  registered by other spec files depending on interleaved (seed-order
  random) execution — this was the source of the recurring
  "prawn: patch should be registered in the version policy" flake. Both
  specs now snapshot and merge-back the registry around each test.
## [0.5.1] — 2026-10-25

### Release housekeeping

- Version bump only. No functional changes.

## [0.5.0] — 2026-10-24

### Performance — read-path hot-loop optimization (measured)

Four changes targeting the per-request class-attribute/config read path,
benchmarked after each against the test app under kino `:ractor` (-w5 -t1,
Ruby 4.0.7, ab c=64):

- **Single-probe IES hit** (`StorageStrategy::Ractor` and all ~53 inline
  eval'd readers): the non-nil IES hit no longer pays a second
  `storage.key?` probe — the stored-nil disambiguation moved to the nil
  path. Semantics identical (a stored nil is still a hit). Micro-bench
  exact-key reader 2.51 → 3.52 Mops/s.
- **Worker IES prefill** (`WorkerApp#setup_once!`): each worker copies the
  frozen shareable fallback table's non-nil slots into its own IES on
  first request, so every later read of fallback-backed config is a
  single first-tier hit. Per-ractor overrides are preserved (key? guard).
- **Boot-time GC.compact** (`prepare_for_ractors!`): one compaction in
  main after the shareabilization passes, before workers spawn.
  Explicitly NOT `GC.auto_compact` (which hangs kino :ractor under load).
  Opt-outs: `RRAILS_SHIM_DISABLE_BOOT_COMPACT=1` / `RUBY_GC_DISABLE_COMPACTION=1`.
- New `bench/accessor_read_bench.rb` micro-benchmark (raw ivar floor vs
  each lookup shape).
- **Compiled callback chains** (`SymbolicTransport` + `Registry`): chains
  compile once per (class, kind) into frozen phase arrays — one ancestor
  walk instead of three per replay, no per-replay `const_get` or
  transport select. Micro-bench: 0.07 → 0.21 Mops/s (3×). E2E POST /posts
  3,000 → 3,445 rps on top of the other changes; `/up` 14,991 → 16,031.

End-to-end (req/s, baseline → full stack; two independent full-stack runs
agreed within noise): `/up` 13,986 → ~15,400 (+7-13%), `/posts_plain`
4,245 → 4,743-4,900 (+12-15%), `POST /posts` 2,442 → 2,728-3,000
(+12-23%), `/posts` (Kaminari, DB-bound) 527 → 548-574 (+4-9%). Memory
flat (~270 MB cold). All 832 unit specs + strategy_proc + integration
spec green.

### Added — multi-database (`connects_to` / `connected_to`) in worker Ractors

Test-app row 81 now runs a real second database, which exposed three gaps in
the worker connection setup:

- `init_worker_ar_connections!` established EVERY configured database on the
  `:default` shard, so in a multi-database app the LAST config won — workers
  queried the secondary database and raised `PG::UndefinedTable` for every
  primary table. The config named `primary` (Rails' convention) now owns the
  default shard; single-database apps fall back to the first entry.
- Each named database is registered for the writing AND the reading role;
  `connected_to(role: :reading)` otherwise raised "calling `connected_to` is
  not allowed when there is no connection defined for that role".
- New `_capture_ar_connection_classes!` (main, prepare time) records every
  model that owns a pool via `connects_to` (Solid Cache/Queue/Cable records,
  app multi-database models) together with the db config main resolved.
  Workers re-establish those pools from the snapshot under the model's own
  `connection_specification_name` — a lazily autoloaded class re-resolved
  `connects_to` to the PRIMARY config (observed: `AuditEntry` queried the
  primary database and its table was "missing").

Evidence: test app `/multi_db_probe` in a worker — secondary write + re-read,
a primary read in the same request, and
`SecondaryRecord.connected_to(role: :reading)`. Suite: 830 runs, 0 failures.

### Added — turbo-rails worker support (test-app rows 105 + 121)

Adopting turbo-rails and exercising ActiveStorage direct uploads in worker
Ractors surfaced five framework-level walls, all fixed here:

- `patches/thread_mattr.rb` (new, install-time): `Module#thread_mattr_reader/
  writer` generate methods that memoize their IES key in a class/module ivar
  (`@__thread_mattr_#{sym} ||=`) — a write that raises IsolationError in
  workers. turbo-rails' `Turbo.current_request_id` (around_action on EVERY
  request) and `ActiveRecord::Base.suppressed_turbo_broadcasts` hit this, so
  every worker request died with a 500. The patched macros emit the
  deterministic key without the ivar memo (same per-class isolation).
- `patches/turbo.rb` (new, prepare-time): re-emits turbo's
  `_render_with_renderer_turbo_stream` renderer as a string-eval'd `def`
  (upstream `define_method`s a main-compiled Proc), and routes PROC layouts
  (`Turbo::Frames::FrameRequest`'s conditional frame layout — re-emitted per
  controller by the Layouts `inherited` hook) through a frozen
  `PROC_LAYOUT_PROCS` registry read by a real `def _layout_from_proc`
  (`instance_exec` preserves the define_method self-rebinding contract).
- `patches/secure_token.rb` (new, install-time): `has_secure_token` registers
  a BLOCK callback — skipped in workers, so worker-created rows had NULL
  tokens (`ActiveStorage::Blob#key` → direct uploads died with
  PG::NotNullViolation). The macro wrapper appends an equivalent Symbol
  callback (and re-applies it to models loaded before the patch, e.g.
  ActiveStorage::Blob).
- `SymbolicTransport::DEFAULT_KINDS` now includes `:initialize` (Rails 8.1's
  `generate_secure_token_on` default) — declared symbolic after_initialize
  filters replay in workers.
- `patches/active_storage.rb`: prebuilds every configured service +
  warms each service's memoized `url_helpers` in main (DiskService#url wrote
  to a frozen instance), registers the blob `service_name` default
  symbolically (seeded `ACTIVE_STORAGE_DEFAULT_SERVICE`), injects that default
  in `create_before_direct_upload!` (the endpoint passes an explicit nil),
  and re-registers `ActiveStorage::SetCurrent` as a Symbol before_action
  (the upstream block never replays → "Missing host to link to!").
- `patches/active_controller.rb`-adjacent constants:
  `ActionController::Parameters::EMPTY_ARRAY/EMPTY_HASH` registered shareable.

Evidence: test app rows 105 (turbo stream responses, `.turbo_stream.erb`
templates, model broadcast enqueued from a worker + performed by `bin/jobs`
with a solid_cable message) and 121 (rich_text_area; full direct-upload
endpoint cycle: POST → signed id/URL → disk PUT → blob redirect → service
URL bytes). Embed parsing remains the documented Nokogiri wall (row 50).

### Fixed — worker-side `:memory_store` / `:null_store` (`Rails.cache` raised FrozenError on the first call)

`Rails.cache` is captured into `CLASS_ATTRIBUTES`. `FallbackBuilder` therefore
deep-froze the store at prepare time.

- `MemoryStore` refreshes LRU order with `@data.delete` / `@data[key] =` on
  every read.
- `NullStore` memoizes `@local_cache_key` on the instance.

Both raised `FrozenError` on the first cache call in every Ractor. The failed
`make_shareable` also froze the live main-Ractor store, so main broke too.
Solid Cache and FileStore were unaffected: they hold no mutable hot-path state.

- `roles/per_ractor_cache.rb` (new): process-local stores are swapped for a
  same-class shareable proxy. `klass.allocate` plus a singleton delegator keeps
  `class` and `is_a?` exact. The proxy holds only a shareable spec (class name
  plus option values that survive `Ractor.make_shareable`). Every store method
  delegates to a `Ractor.current`-memoized instance, so each Ractor gets its own
  `MemoryStore` — the same shape as forked processes. The main Ractor keeps the
  original instance and its boot-warmed entries. `Rails.cache` and
  `ActionController::Base.config.cache_store` are re-pointed at the proxy from
  both `prepare_for_ractors!` and `make_app_shareable!`.
- `patches/active_support.rb`: `SerializerWithFallback::SERIALIZERS` added to
  `SHAREABLE_CONSTANTS`. Worker-side store construction reads it through
  `Store#initialize`. New `_install_cache_store_cattr_patch` re-routes
  `Store.logger` / `raise_on_invalid_cache_expiration_time` through
  `mattr_accessor` when `active_support/cache` loaded before the shim. Workers
  cannot read `@@logger` at all.
- `patches/rails_module.rb`: the worker `Rails.cache` reader returns the proxy
  constant first, then the shareable fallback.
- Redis/MemCache stores are not wrapped. Their connection config is not
  reconstructible from `store.options`. A boot warning tells the operator to
  use `:solid_cache_store` or `:file_store`.
- Spec: `spec/per_ractor_cache_spec.rb` (7 cases: classification, same-class
  shareable proxy, main keeps the original, worker write/read/fetch, per-Ractor
  isolation, NullStore, FileStore unwrapped).

### Fixed — worker-side `serialize :arguments, coder: JSON` (Solid Queue enqueue from a worker, row 110)

Four coordinated fixes, all proven by the test app's `:ractor` suite plus an
end-to-end kino + `bin/jobs` dispatcher run (worker enqueues; the separate
dispatcher performs):

- `patches/solid_queue.rb` (new): prewarms `SolidQueue::Batch.migrated?`
  (a lazily-memoized boolean class ivar on a frozen engine-model class —
  the first worker enqueue died on the `||=` write) and re-registers the
  execution models' `before_create -> { assume_attributes_from_job }`
  BLOCK callback symbolically (`before_create :assume_attributes_from_job`
  via a string-eval'd redefinition of the `JobAttributes` macro). Without
  the latter, SolidQueue's `ScheduledExecution` INSERT died with
  PG::NotNullViolation (null `queue_name`) because SymbolicTransport
  fail-safe skips block filters. Each execution model's current assumable
  list is re-applied (ReadyExecution none/default, ScheduledExecution
  `:scheduled_at`, BlockedExecution `:concurrency_key`).
- `FallbackBuilder.try_make_shareable` no longer blanket-skips
  `__class_attr__queue_adapter`: stateless DB-write adapters (SolidQueueAdapter)
  freeze into the worker fallback so workers enqueue through the REAL
  adapter; unshareable ones (AsyncAdapter's live scheduler) still fall back
  to the declared default.
- `_share_ar_pending_attribute_modifications!` gains a binding-locals
  retry pass + `SerializedTypeDecorator` (callables.rb): decoration Procs
  whose captured locals are unfrozen value objects (e.g. the `serialize`
  macro's `ActiveRecord::Coders::JSON` instance) now freeze those locals in
  place and retry; serialization.rb-sourced decorations that can never be
  shared (`coder ||=` reassignment taints the proc) are reconstructed as a
  shareable callable that rebuilds `Type::Serialized` per apply. WITHOUT
  this, workers rebuilt the `arguments` attribute as a plain Text type and
  stored Ruby hash-inspect instead of JSON (the dispatcher then died with
  JSON::ParserError). SCOPE GUARD: only value-object coders
  (ActiveRecord::Coders::* instances) are reconstructed — coder CLASSES
  (ActionText::Content, whose load path needs Nokogiri — the permanent
  worker wall) keep the pre-fix no-op behavior, preserving row 120's
  raw-HTML round-trip.
- `JsonCoderFreezer` (in patches/active_job.rb): freezes the
  `JSONGemCoderEncoder::CODER` constant's value in main at prepare time so
  the worker-side encode path (called by `ActiveRecord::Coders::JSON#dump`
  through `Type::Serialized#serialize`) can read the constant legally.
- `prepare_for_ractors!` pipeline gains two steps (wired through
  `AppShareabilizer`'s configure seam): `prewarm_solid_queue` and
  `freeze_json_coder`.

### Added — worker-side `around_action` / `:around` callback replay (wrap-style)

Symbolic method-name `:around` filters (`around_action :method`,
`around_save :method`, …) now replay in worker Ractors. `SymbolicTransport`
gains `around(context, kind, inner)` and `Registry#replay` builds a wrap
chain around the single yield. Nesting is pinned against the real
ActiveSupport compiled chain: first-declared `:around` filter outermost, the
after-half runs inside the innermost `yield`, a filter that never yields
suppresses the block and the after-half, and the chain evaluates to the
block's result (a yielding filter's own return value is discarded; a
non-yielding one evaluates to nil). Lambda/Proc around filters remain
fail-safe skipped (un-shareable Procs — same policy as every other Proc
filter). Specs: `spec/callbacks/around_transport_spec.rb`. This resolves the
test-app TODO #90 decision (`around_action`) in favor of shim support.

## [0.4.2]

### Fixed — worker time-zone creation dies on `TZInfo::DataSource`'s class variables

Surfaced by the same durations probe (the layer under the
`ActiveSupport::TimeZone.[]` fix): every `ActiveSupport::TimeZone`
creation resolves its TZInfo data through `TZInfo::DataSource.get`, which
memoizes into the class variables `@@instance` / `@@default_mutex`. Ruby
4.0 forbids ANY class-variable access from non-main Ractors
(`Ractor::IsolationError: can not access class variables from non-main
Ractors`).

- `get` is now Ractor-aware: main keeps the upstream body verbatim
  (class-variable memoize + mutex); workers get a per-Ractor DataSource
  from IsolatedExecutionState built by the upstream private
  `create_default_data_source` (same ruby-data/zoneinfo choice; per-
  instance lookup caches make per-Ractor caching semantically
  equivalent). The upstream `set` (manual source selection) stays
  main-only.

### Fixed — worker `Time.zone` resolution dies on `TimeZone.[]`'s Concurrent::Map class ivar

Surfaced by the test app's durations probe (row 131: `Time.zone` /
`Time.use_zone` from a worker).

- `Time.zone` (and `in_time_zone` / `use_zone`) resolves zones through
  `ActiveSupport::TimeZone.[]`, whose String branch memoizes into the class
  ivar `@lazy_zones_map` — a `Concurrent::Map` set at load time. Both
  halves are forbidden in workers: reading the unshareable Concurrent::Map
  class ivar raises `Ractor::IsolationError` (can not get unshareable
  values from instance variables of classes/modules), and a worker-side
  memoize would try to set it.
- The patched `[]` keeps the upstream body verbatim on main; workers use a
  per-Ractor Hash cache from IsolatedExecutionState. Zone instances are
  plain data and TZInfo lookups are worker-safe, so worker-local caches are
  semantically equivalent. The numeric-offset branch (`all.find`) stays
  main-only (`all` also reads class ivars).

### Fixed — worker-side streaming (`ActionController::Live`) hangs / dies

Surfaced by the test app's blob proxy dispatch (row 127:
`GET /rails/active_storage/blobs/proxy/:signed_id/:filename` in a worker).

- The Active Storage blob proxy controller includes `ActionController::Live`,
  which processes the action on a pool thread: a lazy class-method reader
  sets a class ivar (`@live_thread_pool_executor ||=
  Concurrent::CachedThreadPool.new` — Ruby 4.0 forbids class-ivar writes
  from non-main Ractors, `Ractor::IsolationError`), and `Live#process` then
  blocks on `await_commit` until the spawned thread commits. Even with a
  worker-local pool, the thread hop deadlocks in practice: any exception
  before `commit!` kills the pooled thread (`abort_on_exception = true`)
  and the request hangs forever.
- The patch runs the streaming action INLINE in worker Ractors:
  `new_controller_thread` yields on the request thread (main keeps the
  upstream pool-thread behavior verbatim). The bytes still stream through
  the Rack response body; only true streaming concurrency (early header
  flush) is lost worker-side, which is documented in the row note.

### Fixed — worker `Dependencies.interlock` read dies on the unshareable class ivar

Surfaced by the same blob proxy dispatch (the next frame after the
streaming fix): `ActionController::Live#process` runs the action inside
`ActiveSupport::Dependencies.interlock.running { ... }`, and upstream sets
the `interlock` class ivar at load time to an Interlock wrapping an
unshareable `Concurrency::ShareLock` — reading it from a worker is a
`Ractor::IsolationError` (can not get unshareable values from instance
variables of classes/modules). Regular worker requests don't hit it: the
shim's production stack drops the `ActionDispatch::Executor` middleware,
the only other interlock consumer.

- The reader is replaced with a Ractor-aware method: main returns the
  upstream class ivar (100% upstream semantics); workers get a per-Ractor
  Interlock from IsolatedExecutionState. Workers never reload (the graph
  is frozen), so the per-Ractor lock never contends. The upstream writer
  (`interlock=`) is untouched.

### Fixed — `config_for` / method_missing-backed config reads die in workers (`@@options` class variable)

Surfaced by the test app's `GET /features/config_probe` (rows 115/134/138:
read the production SMTP shape, `config.x`, and `config_for(:audit)` from a
worker).

- **`Rails::Railtie::Configuration` stores its method_missing option hash in
  the class variable `@@options`**, and Ruby 4.0 forbids ANY class-variable
  access from a non-main Ractor (`Ractor::IsolationError: can not access
  class variables from non-main Ractors`) — so any worker-side read of an
  option that is not an explicit method (e.g. `config.x`) died.
- The patch is installed with `class_eval` (NOT prepend): Ruby forbids
  class-variable access from a prepended module ("class variable @@options
  ... is overtaken by <module>"), and even a non-accessing worker branch
  would be compiled into the module. Methods defined via class_eval on the
  class itself legally own the cvar, so the main branch delegates to the
  aliased originals — 100% upstream semantics on main.
- Workers read through a **frozen snapshot** of the main-side `@@options`,
  taken by the AppShareabilizer freeze pipeline (after Proc/Map/Lock
  replacement, before the final make_shareable) and stored as the frozen
  constant `RRS_FROZEN_OPTIONS` on the class (constants are shareable; the
  class variable is not). Per-value `make_shareable` with rescue:
  non-shareable leftovers (lock objects) are skipped. A per-Ractor IES
  overlay (keyed by the config object's identity) covers worker-local
  writes. Unknown names raise NoMethodError in workers instead of falling
  through to the original (whose @@options access is forbidden).

### Fixed — intermittent worker `NoMethodError: undefined method 'owned?'` on NoOpLock

Observed ~1-in-7 kino runs on `GET /`: a worker hit
`Concurrent::Synchronization::MutexLockableObject#synchronize`, which (since
concurrent-ruby 1.3.8) checks `@__Lock__.owned?` before locking — and the
shim's `NoOpLock` (the shareable stand-in swapped for `Mutex`/`Monitor`
ivars during the graph freeze) didn't define `owned?`. Added
`def owned?; true; end`: callers take the direct-yield path, which is the
correct semantics for a never-contended post-boot lock.

### Fixed — `normalizes` breaks every User-touching worker route (DelegateClass types poison `instance_method` cross-Ractor)

Surfaced by the test app's `GET /features/normalizes_probe` (TODO P2 #3,
row 74: `User normalizes :email, with: ->(v) { v.strip.downcase }`).

- **`SerializeCastValue::ClassMethods#serialize_cast_value_compatible?` is not
  DelegateClass-safe in workers** (`patches/activerecord.rb`): adding
  `normalizes` to User wraps the attribute type in
  `ActiveModel::Attributes::Normalization::NormalizedValueType`, a
  `DelegateClass` subclass. DelegateClass defines its delegator methods via
  `define_method` with **Proc bodies created in the defining Ractor**, and
  Ruby 4.0 refuses `instance_method` / `instance_methods` on such classes
  from another Ractor (`RuntimeError: defined with an un-shareable Proc in
  a different Ractor`) — even for plain `def` methods on the same class.
  The shim's IES-backed patch of `serialize_cast_value_compatible?` calls
  `instance_method(...)` for every type construction, so ANY worker touching
  User attributes boomed (Devise before_actions, mail probes, attach probes,
  the root page, POST /posts...). The patch now rescues the cross-Ractor
  error and recomputes with table snapshots only —
  `method_defined?(sym, false)` per ancestor (verified safe cross-Ractor) —
  reproducing the same first-owner comparison as upstream without Method
  objects. Per-class IES key unchanged.

### Fixed — worker-side ActiveRecord enums (row 65)

Four worker-hostile method families generated by AR enums:

- predicates/bangs + class-level values reader + per-value scopes are
  define_method'd with Procs compiled inside `_enum_methods_module` (a
  Module the proc-replacement traversal cannot reach — it walks ivars,
  not method tables) or singleton define_method Procs capturing
  name/value locals that workers replay with a lost binding (NameError).
- Fix: the enum methods are re-defined as string-eval'd REAL defs (the
  predicate compares `#{attr}_for_database`, bangs write via `update!`,
  scopes build `all.where`/`where.not`, the pluralized reader returns a
  const-backed frozen HWIA). Safe because Rails' `detect_enum_conflict!`
  guarantees no user method occupies these names.

### Fixed — worker-side validations silently passed everything (rows 1+98)

Worker-side `valid?` returned TRUE with zero errors — invalid records
could save in workers (data corruption). Root causes, all fixed:

- The set_callback interceptor only recorded Symbol filters;
  Validator-object filters (ActiveModel::Validator instances registered
  by `validates` / `validates_with`) were never captured. The shim now
  builds a shareable descriptor `{validator-class-name, attributes,
  options, declaring-class}` and the SymbolicTransport rebuilds a fresh
  validator in the worker and calls `.validate(record)` (return value
  ignored — validators signal via errors, never halt).
- Phase parsing: Rails passes the phase as filter_list[0] only when
  explicit; no-explicit-phase declarations (`validate :sym`) were
  silently missed (parsed per normalize_callback_params).
- DEFAULT_KINDS was missing `:validate` (the ActiveModel validations
  chain), and the interceptor predicate now includes ActiveRecord::Base
  itself so Base-level declarations replay.

### Fixed — DelegateClass "special" methods, ActionView date selectors, CurrentAttributes keys in workers

- Ruby's delegate.rb defines every DelegateClass(X)'s "special" methods
  (incl. `<<`) via `define_method(Delegator.delegating_block(m))` —
  main-compiled lambdas that workers cannot call. They are detected by
  shared source_location with a delegating-block marker and redefined as
  string-eval'd defs. Fixes multipart parsing in workers
  (Collector#on_mime_body calls Tempfile#<<).
- ActionView's DateTimeSelector#sec/min/hour/day/month/year (upstream
  `define_method(&block)`) redefined as real defs — `date_select`
  rendered NoMethodError in workers; plus a SelectType patch for select
  helpers.
- CurrentAttributes' key-generated methods raised on frozen module reads
  in workers — `Current.request_id` now round-trips.

### Fixed — worker-side Solid Cache (:solid_cache_store) round-trip; connects_to pool fallback; broken `reset_table_name` super

Surfaced by the test app's `GET /solid_cache_probe` (TODO #27: verify rows
45–47 against the REAL production store instead of the kino's historical
`:null_store` no-op path).

- **Broken `super` in the `reset_table_name` patch** (`patches/activerecord.rb`):
  the shim's ModelSchema patch was installed via
  `ModelSchema::ClassMethods.module_eval`, which REPLACES the original
  `reset_table_name` in place — so the override's `super` skipped past the
  module and found nothing. Every lazy main-side `reset_table_name` after
  patch install raised `NoMethodError: super: no superclass method
  'reset_table_name'` (silently swallowed by the warm passes' rescues). The
  visible victims were HABTM join models, whose table names resolve lazily
  through the builder's `table_name_resolver` AFTER patch install: their
  `@table_name` never materialized and the resolver lambda survived the
  graph freeze unfrozen, so worker-side HABTM writes died with
  `IsolationError ... (@table_name_resolver from Post::HABTM_Tags)` —
  with a heap-layout-sensitive failure rate that made the kino flaky across
  shim changes. The override now captures the original via `alias_method`
  and calls it explicitly; `ShareabilityTraversal.harden_ar_model_ivars!`
  (called right before the graph freeze) additionally materializes join-model
  `@table_name` and freezes the resolver lambda, with loud warnings instead
  of silent skips.

- **connects_to pool fallback** (`patches/activerecord.rb`):
  `init_worker_ar_connections!` + the patched `connection_pool` /
  `retrieve_connection` / `connected?`. connects_to-style models (Solid
  Cache / Solid Queue / Solid Cable) own their pool in the MAIN handler under
  their CLASS name (`connects_to` sets `@connection_specification_name`) and
  carry their own `default_shard` class_attribute (e.g. SolidCache::Record
  gets `default_shard == :primary` from config/cache.yml `database: primary`),
  while the worker handler only seeded Base-level (role, :default) pools —
  workers querying such a model died with
  `ConnectionNotDefined: No database connection defined for
  SolidCache::Record with 'primary' shard`. Two fixes: (1) the worker seed
  also registers each named env database config under its own name as a
  shard key (the standard `connects_to database: <name>` convention), and
  (2) the patched readers fall back to the Base-level pool for the same
  role/shard when the class-owned pool is not present in the worker.
- **Per-Ractor `SolidCache::Entry.select_sql` memo**
  (`patches/solid_cache.rb`, new): the read path memoizes per-keys-count SQL
  in the class ivar `@select_sql` — a worker cannot write class ivars
  (IsolationError). The singleton method now routes the memo through
  Ractor.current in workers; main keeps the original lazy-memo semantics.

### Fixed — worker-Ractor mail hooks + ActiveJob `set(wait:)` enqueue; deterministic HABTM shareability

Surfaced by the test app's worker-Ractor audit of mail hooks (matrix rows
113/116) and ActiveJob enqueue options (rows 107/108). Verified by
`GET /stats/mail_hooks_probe` (interceptor + mailer-callback headers stamped on
worker-delivered mail) and `GET /features/job_resilience_probe`
(`set(queue:, wait:)` enqueue + rescue-handler config readable from a worker).

- **Mail hook registry snapshot** (`patches/mail.rb` +
  `AppShareabilizer.make_shareable!`): the mail gem's
  `inform_interceptors` / `inform_observers` read raw class variables, and the
  shim's worker branch historically returned a per-worker EMPTY list —
  interceptors/observers registered in main during boot silently never ran in
  workers. The registries are now snapshotted as a frozen list of hook NAMES
  (`RactorRailsShim::MAIL_INTERCEPTORS` / `MAIL_OBSERVERS`) AFTER the app-graph
  freeze; workers resolve the constants and run the same hook objects main
  registered. Non-module hooks (stateful instances) are skipped with a warning.
  Placement note: the snapshot deliberately runs post-freeze — earlier
  placements perturbed the heap-layout-sensitive make_shareable walk.
- **Deterministic HABTM join-model freeze**
  (`ShareabilityTraversal.harden_ar_model_ivars!`, called right before the
  graph freeze): HABTM join models resolve their table name through a lazy
  resolver lambda (`@table_name_resolver = -> { table_name }`). Whether the
  make_shareable walk reached it was heap-layout sensitive — some
  configurations left it unfrozen and every worker-side HABTM write
  (`post.tags << tag`, dependent destroys) died with
  `IsolationError ... (@table_name_resolver from Post::HABTM_Tags)`. The
  explicit freeze (run after Proc/Map replacement cleaned the graph, so it
  succeeds) makes worker-side HABTM deterministic.
- **Per-Ractor Concurrent global executors**
  (`_install_concurrent_global_timer_set_patch`): a worker-side
  `set(wait:)` enqueue schedules via `Concurrent::ScheduledTask`, whose default
  timer/notification path reads the unshareable `GLOBAL_TIMER_SET` /
  `GLOBAL_IO_EXECUTOR` / `GLOBAL_FAST_EXECUTOR` constants —
  `IsolationError: can not access non-shareable objects in constant
  Concurrent::GLOBAL_TIMER_SET by non-main ractor`. The readers now give each
  worker its own TimerSet / ThreadPoolExecutor through IES; main keeps the
  global instances.

### Fixed — Rails 8.1 `signed_id` / `find_signed` / `token_for` from a worker Ractor

`User.find_signed(params[:token])` from a worker Ractor died with
`NoMethodError: undefined method '[]' for ... NoOpProc`: the signed-id salt
("active_record/signed_id") builds its verifier codec LAZILY on first use, and
by the time a worker asks, the coordinator's rotation Proc / secret generator
have become NoOpProcs (Proc replacement) on a frozen graph. Verified by the
test app's `GET /features/signed_id_probe` → `generate` / `find_signed` round
trip from a kino `:ractor` worker.

- **Codec pre-warm** (`ShareabilityTraversal.prewarm_message_verifier_codecs!`,
  called from `prepare_for_ractors!` right after the ActiveStorage prefix
  seed): main builds the lazily-created codecs ("active_record/signed_id",
  "active_record/token_for") up front so workers hit the frozen `@codecs`
  cache. The salt list is deliberately method-local — load-time allocations in
  the shim used to perturb the order-sensitive attribute-method generation
  downstream.
- **`SerializerWithFallback.serializer_for` NameError fix**
  (`patches/active_support.rb`): the patch is string-eval'd on the singleton
  class, where a bare `SERIALIZERS` reference raises NameError (cref ancestors
  exclude the module). Now fully qualified:
  `::ActiveSupport::Messages::SerializerWithFallback::SERIALIZERS.fetch(format)`.
- **stdlib `JSON` default-option ivars** (`patches/make_shareable.rb`): the
  legacy signed-id rotation passes `serializer: JSON` (stdlib), and JSON
  memoizes `@dump_default_options` / `@load_default_options` / etc. as class
  ivars — workers could not even read them (`IsolationError ... from JSON`).
  Registered in `SHAREABLE_CLASS_IVARS` so they deep-freeze at prepare time.
- **`MessageVerifier#digest_length_in_hex` memo patch**
  (`patches/active_support.rb`): the lazily memoized `@digest_length_in_hex
  ||=` writes to the deep-frozen verifier at first generate/verify —
  `FrozenError: can't modify frozen ActiveSupport::MessageVerifier`. Replaced
  with a direct `OpenSSL::Digest` computation (allocation is negligible next
  to the HMAC itself).
- **`ActiveRecord` attribute-state robustness** (`patches/active_model_attribute.rb`):
  in MAIN, `attribute_types` / `_default_attributes` no longer memoize through
  `RactorRailsShim.storage` — that memo had no invalidation path in main
  (`reset_column_information` cannot see it), so an empty type-set built
  before a model's schema settled poisoned `attribute_names` permanently.
  Main now uses the upstream class-ivar memo (which every reset path clears);
  workers keep the per-Ractor IES path.
- **Prefix-seed ordering fix** (`roles/lifecycle.rb`): `_seed_active_storage_prefix!`
  now runs BEFORE `install_framework_patches`. The AR model-classes patch runs
  `load_schema` on every concrete model at install time; with the prefix
  unseeded, ActiveStorage models computed table names like `"attachments"` and
  the failing attempts poisoned memoized attribute state —
  `generate_ar_attribute_methods!` then generated modules missing column
  writers, and workers lost `ActiveStorage::Attachment#name=` (DelegationError
  on `Attachment.new`). Seeding first closes that window.
- Dispatch list updated in `spec/framework_patch_dispatch_spec.rb` for the new
  `_install_message_verifier_digest_memo_patch`.

### Fixed — shim TODO #5: ActiveJob `perform_later` / `deliver_later` from a worker Ractor

The last code-level ❌ in `FEATURES.md`. `WelcomeJob.perform_later(user)` from
a worker Ractor crashed with two different walls; both fixed. Regression specs
in `spec/cgi_escape_patch_spec.rb`; verified end-to-end by the test app's
`GET /job_enqueue_probe` → 200 `{enqueued: true, job_class: "WelcomeJob"}`
from real kino `:ractor` workers.

- **`GlobalID.app` captured via `SHAREABLE_CLASS_IVARS`** (`["GlobalID",
  :@app]`, `patches/make_shareable.rb`). The railtie sets it to an *unfrozen*
  String, and workers cannot even READ an unfrozen class ivar —
  `GlobalID.create` (any ActiveJob argument serialization) died with
  `IsolationError: can not get unshareable values from instance variables
  ... (@app from GlobalID)` before GlobalID's own "An app is required" check
  even ran. Deep-frozen at prepare time like the other captured ivars.
- **New `patches/cgi.rb`** — `CGI::Escape`/`CGI::EscapeExt` default their
  `unescape` / `unescapeURIComponent` encoding argument to the
  `@@accept_charset` CLASS VARIABLE (the C ext impl from `cgi/escape.so`
  reads it internally too). Ruby forbids reading class variables from
  non-main Ractors outright — even shareable ones. globalid's URI::GID
  parsing calls `CGI.unescape`, putting this on the enqueue path. Both
  methods are re-defined (string eval, shareable) defaulting to a frozen
  snapshot constant; wired into the Ractor install strategy before eager
  load. Requires no behavior change: explicit-encoding calls keep working,
  and the class variable storage is untouched for main-Ractor callers.
- **`queue_adapter` needed no shim change**: ActiveJob's reader lazily
  instantiates a per-worker adapter (`self.queue_adapter = :async if
  _queue_adapter.nil?`) through the class_attribute IES writer, which
  already works in workers.

### Fixed — worker-Ractor cache access (low-level Rails.cache + fragment caching)

Exercising the caching audit in the test app surfaced three isolation walls
that made ANY cache call (`Rails.cache.fetch`, view fragment caching) die in a
worker Ractor. All fixed; regression specs in
`spec/cache_option_aliases_shareable_spec.rb`.

- **`ActiveSupport::Cache::OPTION_ALIASES` registered in
  `SHAREABLE_CONSTANTS`** (`patches/active_support.rb`). Rails freezes the
  Hash shallowly — its Array values stay unfrozen — so workers could not even
  READ the constant (`IsolationError` in `Store#normalize_options` →
  `merged_options`), which broke every `fetch`/`read`/`write` with an options
  hash. Deep-frozen at boot like the other read-only alias maps.
- **`ActiveSupport::Cache::Coder` constants registered** (`PACKED_TYPE_
  TEMPLATE`, `PACKED_EXPIRES_AT_TEMPLATE`, `PACKED_VERSION_LENGTH_TEMPLATE`,
  `STRING_DESERIALIZERS`, `STRING_ENCODINGS`) — read during cache-entry
  deserialization (`Coder#load`); the next wall behind OPTION_ALIASES.
- **Cache serializer availability probes warmed in main**
  (`_warm_cache_serializer_fallbacks!`, new step in the `AppShareabilizer`
  pipeline between `_warm_attribute_method_patterns!` and
  `_freeze_declared_callbacks!`). The `SerializerWithFallback` fallbacks
  (Rails 8.1: `module ... extend self`) memoize `available?` as an ivar on
  the module object; a worker making the first probe crashed on the ivar
  WRITE (`can not set instance variables of classes/modules by non-main
  Ractors`) during `Coder#load` → `dumped?`. Warming the probes before the
  freeze leaves `defined?(@available)` true with a shareable boolean.
- **`ActiveSupport::NumberHelper` converter constants registered**
  (`NumberConverter::DEFAULTS`, `NumberToDelimitedConverter::
  DEFAULT_DELIMITER_REGEX`, `NumberToHumanConverter::DECIMAL_UNITS` /
  `INVERTED_DECIMAL_UNITS`, `NumberToHumanSizeConverter::STORAGE_UNITS`) —
  read on every `number_with_delimiter` / `number_to_currency` / human-size
  call; `DEFAULTS` was entirely unfrozen. Needed once views render number
  helpers from worker Ractors.

Verified end-to-end: the test app's fragment / russian-doll / low-level
caching and number-helper views now serve from real kino `:ractor` workers
(`root_load_test.rb` passes; full suite 111 runs / 0 failures / 0 skips).

Verified end-to-end: the test app's kino (`:ractor` kino, production
semantics) exercises streaming blob proxy serving, worker-side time
zones, the error reporter, config reads, the public Active Storage
service, the analyzer chain, and Solid Cache writes with expiry; the
full test suite is 180 runs / 787 assertions / 0 failures and the shim
spec suite is 804 runs / 1699 assertions / 0 failures / 4 skips.

## [0.4.1]

### Fixed — community-reported crash trio (GitHub issues #1, #2, #3)

All three were triggered by the same docs gap: thread-mode users calling
`prepare_for_ractors!` (Ractor-mode-only) because the README presented it
unconditionally. Two real code defects were also exposed and fixed.

- **`prepare_for_ractors!` now skips itself in thread mode** with a loud
  warning (`roles/lifecycle.rb`). It is Ractor-mode-only: it dispatches the
  full per-Ractor patch set and deep-freezes live Rails objects, which
  breaks thread servers (Puma/Falcon/Thin/Webrick). Running it in thread
  mode froze the main Ractor's live `DatabaseConfigurations::HashConfig`
  objects → `FrozenError` in `Migration::CheckPending` on every dev HTTP
  request. (Fixes #2; root cause of the trigger conditions in #1 and #3.)

- **`SHAREABLE_AUTOSAVE_REFLECTIONS` registry swap made atomic**
  (`patches/activerecord.rb`). `_rrs_store_autosave_reflection` removed the
  constant before calling `Ractor.make_shareable`, so an unshareable
  reflection (e.g. one capturing a Proc) left the constant permanently
  missing and every later association declaration raised
  `NameError: uninitialized constant SHAREABLE_AUTOSAVE_REFLECTIONS` on
  boot for any app with ActiveStorage attachments. Now compute-then-swap
  (a failure leaves the previous registry intact) plus self-healing (a
  missing constant is re-seeded on the next store). (Fixes #1.)

- **`action_methods` nil cache read fixed** in both patched copies
  (`AbstractController::Base` and `AbstractController::UrlFor::ClassMethods`,
  `patches/action_controller.rb`). `instance_variable_defined?` is true for
  defined-but-nil ivars, and `clear_action_methods!` (Rails' invalidation
  hook, hit while a mailer/controller class body is evaluated) sets
  `@action_methods = nil` — so the next call read nil, cached nil, and
  returned it, raising `NoMethodError: undefined method 'include?' for nil`
  in `ActionMailer::Base#respond_to_missing?` (crashed `bin/rails
  db:migrate` during a kamal release phase). (Fixes #3.)

### Changed — docs
- README Install section split into two explicit tracks (Ractor mode with
  kino vs Thread mode with Puma/Falcon/Thin/Webrick), with warnings that
  `prepare_for_ractors!` / `make_app_shareable!` must never be called in
  thread mode.

## [0.4.0]

### Added — Rails feature support for worker Ractors
- **`render json:` / `render xml:` / `render js:` in worker Ractors.**
  ActionController::Renderers defines `_render_with_renderer_*` via
  `define_method(&block)` at boot — the block is compiled in the main Ractor
  and can't be called from a worker. Redefined all three as string-eval'd
  `def`s (no captured binding) callable from any Ractor.
  (`_install_json_renderer_patch`, `patches/action_controller.rb`)

- **ActionMailer `deliver_now` from a worker Ractor.** The full build +
  ERB render + deliver path works in a worker Ractor. Patches the `mail`
  gem (raw `@@cvar`s routed through per-Ractor IES; `Mail::Configuration`
  per-worker; `Mail::Parsers::*Parser` + `Mail::Utilities` module ivars
  captured into a shareable constant with string-eval `def` readers;
  `Mail::TestMailer.deliveries` per-Ractor; `Mail::PartsList` /
  `AttachmentsList` `DelegateClass` delegating methods redefined as
  shareable `def`s). Patches `ActionMailer::Base` (`mailer_name` callers
  reimplemented via string-eval; `PROTECTED_IVARS` made shareable; `config`
  falls back to empty `OrderedOptions` when `class_attribute` resolves nil;
  `local_prefixes` overridden for mailers). SMTP delivery also viable
  (`Mail::SMTP::DEFAULTS` made shareable). (`patches/mail.rb`)

- **ActiveStorage `has_one_attached` in a worker Ractor.** Blob creation,
  file upload, attachment persistence, and cross-worker read-back all work.
  16 patched layers:
  - `has_one_attached` / `has_many_attached` scope lambda built with a
    shareable `self` so `User.reflections` is Ractor-shareable.
  - `Blob.build_after_unfurling` / `compute_checksum_in_chunks` redefined
    without `tap` blocks.
  - `Blob#service_name` falls back to `self.class.service&.name`.
  - `Blob.type_for_attribute(:metadata)` / `attribute_types` / per-worker
    `_default_attributes` force `Type::Serialized` with
    `IndifferentCoder(JSON)` for `:metadata`.
  - `generated_attribute_methods` modules captured in
    `SHAREABLE_GEN_ATTR_METHODS` at prepare time; workers read via per-Ractor
    IES instead of creating an empty Module.
  - `ActiveRecord::Store#store_accessor` redefined as string-eval `def`s;
    `store_accessor_for` coder resolution block-free.
  - `ThroughReflection#source_reflection_name` respects `options[:source]`.
  - `ThroughReflection#check_validity!` uses per-worker cache (was writing
    `@validated` on frozen reflection → FrozenError).
  - `full_table_name_prefix` / `full_table_name_suffix` reimplemented
    without un-shareable `module_parents.detect { }` blocks.
  - `attribute_names` aliased to `_rrs_orig_attribute_names` (was `super`
    with no superclass method); `define_attribute_methods` calls original
    in main (was no-op everywhere).
  - `SecureRandom::BASE36_ALPHABET` / `BASE58_ALPHABET` deep-frozen at
    `prepare_for_ractors!` time.
  - `ActiveStorage.table_name_prefix` / `table_name_suffix` redefined as
    shareable string-eval `def`s; `_seed_active_storage_prefix!` seeds
    constants and resets `Blob`/`Attachment` `table_name` in main.
  - `Marcel::MimeType` / `Marcel::Magic` block-based methods redefined as
    string-eval `def`s; lookup tables frozen.
  - `ActiveStorage::Service::Registry#fetch` works via `class_attribute`
    fallback.
  - `Devise.mailer` `@@mailer_ref` cvar captured as shareable constant;
    workers read the captured copy.
  - Callback `if:` / `unless:` Symbol conditions captured and checked via
    `condition_allows?` in SymbolicTransport.
  (`patches/active_storage.rb`, `patches/active_record_store.rb`,
  `patches/marcel.rb`, `patches/active_model_attribute.rb`,
  `patches/activerecord.rb`, `patches/activerecord_reflection.rb`,
  `patches/devise.rb`, `callbacks/symbolic_transport.rb`,
  `roles/callback_capture.rb`, `roles/shareability_traversal.rb`)

- **`FEATURES.md` — feature support matrix.** Documents every supported /
  unsupported / unverified feature for worker Ractor mode, with known
  limitations (around callbacks, sanitize/Nokogiri, ActiveJob
  `perform_later`, block `after_save` workaround, GlobalID
  `after_create_commit` workaround).

### Known limitations
- `around_action` / `:around` callbacks — not transported (must wrap yield).
- `sanitize` / `simple_format` (Nokogiri) — ractor-unsafe C extension.
- ActiveJob `perform_later` / `deliver_later` — `queue_adapter`
  `class_attribute` resolves nil in workers; `GlobalID.app` class ivar not
  captured by the shim (nil in workers). **TODO #5**.
- `has_one_attached` block `after_save` callback — lambda can't cross
  Ractor boundary. Probe uses `blob.unfurl` + `insert!` workaround.
- `ActiveStorage::Attachment` `after_create_commit` callbacks — enqueue
  ActiveJobs via GlobalID (`@app` nil in workers). Probe uses `insert!`.

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
