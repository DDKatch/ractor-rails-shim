# Gem Compatibility Matrix

Which gems work with `ractor-rails-shim` out of the box, which need patches,
and which are fundamentally incompatible with Ractor mode.

> **Methodology.** Each gem is classified by how it holds global state
> (class-level instance variables, class variables, constants, instance
> Mutexes, or captured Procs/closures) — the exact attributes the shim's
> audit (`ractor-rails-check`) inspects. Classifications marked **verified**
> were run against the gem; those marked **analyzed** are derived from the
> gem's source patterns (the storage class is known, but the gem wasn't
> loaded in a test app). Run `bundle exec ractor-rails-check --app` against
> your own app to get the authoritative list for your dependency set — this
> doc is a starting map, not a guarantee.

## Legend

| Status | Meaning |
|---|---|
| ✅ | Works out of the box. The shim reroutes its global storage, or it has no class-level mutable state. |
| ⚠️ | Needs a targeted patch. The gem uses raw `@ivar`/`@@cvar`/Mutex/Proc the shim doesn't auto-fix; patch it in the shim or upstream. |
| ❌ | Fundamentally incompatible. The gem's design (pervasive shared mutable state, process-identity assumptions) can't run in a frozen read-only shared app. Run it in a separate process. |

## Matrix

| Gem | Status | Storage class | Shim auto-fixes? | Notes |
|---|---|---|---|---|
| **rails** (8.1) | ✅ verified | mattr/cattr + class_attribute + constants + 7 Procs | yes (via `make_app_shareable!`) | The shim's whole purpose. Full-stack app (AR + Devise 5 + Propshaft + Kaminari + PG) dispatches every routable action in worker Ractors under `kino -m ractor`: `/up`, `/posts` (index/show/new/edit), Devise sign-in/sign-out (CSRF issue + validate), authenticated `POST /posts` → 302 (row persisted), `DELETE/PATCH /posts/:id`. |
| **actionview** — `sanitize` / `simple_format` (HTML sanitization) | ❌ **worker Ractor only** | Nokogiri (C ext) | no | `sanitize` / `simple_format` → `Loofah` → `Nokogiri::Document.new`, a **ractor-unsafe C method**: Ruby only permits it in the **main Ractor**, so worker Ractors raise `ractor unsafe method called from not main ractor`. (This is *not* the usual "run in a separate process" ❌ — it works fine in **thread mode** (Puma/Falcon) and in the **main Ractor**; only **worker Ractors** are blocked.) No shim patch can fix it — you can't make a C method shareable, and re-loading Nokogiri inside the worker doesn't help (the guard keys on the calling Ractor being main, not on how the code was loaded). Workarounds: avoid these helpers in worker-rendered views, offload sanitization to `Ractor.main`, or wait for upstream Nokogiri Ractor-safety. |
| **propshaft** | ✅ analyzed | class_attribute + constants | yes | Static asset server; no per-request class state. |
| **puma** | ✅ analyzed | n/a (instance state) | n/a | Server, not in the app graph. Per-Ractor workers are the server's job (Kino/Puma), not the shim's. |
| **kino** | ✅ verified | — | n/a | The Ractor web server; runs `:ractor` mode against the shareable app. |
| **devise** | ✅ verified | mattr_accessor (mostly) + Warden closures | yes (with Warden patch) | Config is mattr → shim fixes. **Warden::Hooks** lazy class ivars (`@_on_request ||= []` etc.) patched: workers treat callback arrays as empty (correct for read-only shared app). Full Devise stack (sign-in, sign-out, CSRF issuance + validation, authenticated writes) dispatches in `kino -m ractor` worker Ractors → 200/302/303. |
| **warden** | ✅ verified (with patch) | class ivars + Procs | yes (shim patch) | `Warden::Hooks` has 6 lazy class ivars (`@_on_request`, `@_after_set_user`, `@_before_failure`, `@_after_failed_fetch`, `@_before_logout`, `@_on_request`) that lazily init at request time on the frozen middleware instance → IsolationError. Shim patches all 6 to return `[]` in workers (callbacks ran in main at boot). |
| **sidekiq** | ❌ analyzed | class ivars + Mutex + process-identity | no | Background job processor with pervasive shared mutable state, Redis connection pools, and a global scheduler loop. **Not a request-path dependency** — run it in a separate process. If your app merely *enqueues* jobs per-request, `Sidekiq::Client.push` reads `Sidekiq.redis_pool` (class ivar + Mutex) → would need a patch; prefer enqueuing via a shared Redis client built per-Ractor. |
| **sidekiq** (web dispatch only) | ⚠️ analyzed | `Sidekiq.options` class ivar | no | Only relevant if the app reads Sidekiq config during a request. Raw `@options`/`@redis_pool` class ivars raise IsolationError → patch the reader through IES (per-Ractor client) or avoid touching Sidekiq in the request path. |
| **redis** (redis-rb) | ⚠️ analyzed | instance Mutex + socket IO | n/a (instance) | `Redis::Client` holds a command `Mutex` and a socket — both **instance-level**, unshareable, but fine *if each Ractor builds its own client* (don't share one). `Redis.current` (deprecated class ivar) would block → don't use it; use a per-Ractor connection. |
| **pg** | ✅ analyzed | instance state + `PG::BasicTypeRegistry` | yes (via AR) | `PG::Connection` instances hold a socket (per-pool, per-Ractor via AR's `connection_handler` which Rails already IES-routes). Class-level registry state is minimal and shareable. |
| **mysql2** / **trilogy** | ✅ analyzed | instance state | yes (via AR) | Same shape as `pg`: connections are per-Ractor via AR's connection pool. |
| **activerecord** | ✅ verified | mattr + `connection_handler` (already IES) | yes | `connection_handler` is the one Rails global already migrated to `IsolatedExecutionState`. Per-Ractor connection pools work; each worker gets its own. (Caveat: large schemas / `default_scope` use class ivars — run `ractor-rails-check`.) |
| **viewcomponent** | ⚠️ analyzed | class_attribute + `@vc_*` ivars | partial | Config uses `class_attribute` (shim fixes). Component compile caches use raw `@_after_compile` / `@_sidecar` class ivars → may need the shareable-fallback treatment. `default_preview_paths` is class_attribute (fixed). |
| **kaminari** | ✅ analyzed | mattr_accessor | yes | Config (`default_per_page`, `max_pages`, `window`) is all mattr. |
| **pagy** | ✅ analyzed | `Pagy::DEFAULT` constant | yes (if frozen) | Config is a frozen Hash constant → shareable. No class ivars. |
| **ransack** | ⚠️ analyzed | mattr + raw ivars | partial | `Ransack.configure` uses mattr (fixed); `Ransack::Search` has raw `@_options` class ivars in some adapters. |
| **friendly_id** | ✅ analyzed | mattr_accessor | yes | Config is mattr. |
| **acts_as_taggable_on** | ✅ analyzed | mattr_accessor | yes | Config is mattr. |
| **faraday** | ⚠️ analyzed | class ivars + Mutex | no | `Faraday::MiddlewareRegistry` has `@middleware_mutex` (Mutex) + `@registered_middleware` (Hash). Needs NoOpLock replacement (like the app-graph locks) or a targeted IES patch. Connection *instances* are fine per-Ractor. |
| **httparty** | ✅ analyzed | class-level defaults (Hash) | yes (if frozen) | `HTTParty.default_options` is a class ivar holding a Hash → make shareable or seed per-Ractor. |
| **http.rb** | ✅ analyzed | instance state | yes | Stateless at the class level. |
| **jwt** | ⚠️ analyzed | class ivar `@config` | no | `JWT.configure` stores in `JWT::Configuration` singleton `@config`. Needs an IES-routed reader/writer patch. |
| **dry-configurable** / **dry-system** | ❌ analyzed | class-level `setting` macro + Mutex | no | `Dry::Configurable` stores settings in class ivars; `Dry::Container` uses a `Mutex`. Pervasive class state across the dry-rb stack. Needs either a shim patch per-class or upstream changes. |
| **aws-sdk** (aws-sdk-* ) | ❌ analyzed | `Aws.config` mutable Hash + global credentials | no | Heavy global mutable state (`Aws.config`, credential providers, region defaults). Designed for process-wide singletons. Run AWS calls in a separate process or build clients per-Ractor. |
| **google-cloud-* / fog** | ⚠️ analyzed | class-level config | partial | Similar to aws-sdk but lighter. `Fog.credentials` is a class ivar Hash. |
| **sentry-ruby** / **sentry-rails** | ⚠️ analyzed | `Sentry.configuration` singleton + Mutex | no | `Sentry::Hub` holds a Mutex and the config is a process singleton. The Rails integration subscribes to AS::Notifications (per-Ractor no-op in the shim's worker model). Needs a targeted patch for the config singleton, or run Sentry in a separate process. |
| **bugsnag** / **honeybadger** | ⚠️ analyzed | class-level config singleton | no | Same shape as Sentry: process-global config + a background thread for delivery. |
| **bootsnap** | ✅ analyzed | cache files + `Bootsnap::LoadPathCache` | n/a | Boot-time only; the cache is built before `make_app_shareable!` and isn't read at request time in production. |
| **lograge** | ✅ analyzed | class_attribute | yes | Config is class_attribute. |
| **bullet** (dev) | ⚠️ analyzed | class ivars + instance Mutex | no | Dev-only. `Bullet` holds `@enable`, `@warnings`, `@detected_associations` (class ivars) + an instance Mutex. Disable in production Ractor mode (it's a dev tool). |

## Patterns

### Gems that work (✅)
Two flavors: (a) **mattr/class_attribute-backed config** — the shim's macro
rewrites reroute these through IES automatically (Kaminari, FriendlyId,
Lograge). (b) **instance-state-only** gems where each Ractor builds its own
objects — no class-level state to share (http.rb, pg connections via AR's pool).

### Gems that need a patch (⚠️)
They use **raw `@ivar`/`@@cvar`** (not the mattr/class_attribute macros) or
hold **instance Mutexes / captured Procs** in shared objects. The fix is one
of:
- **IES-route the accessor** (same technique as the shim's
  `_install_active_support_error_reporter_patch`): define a string-eval'd
  reader/writer that reads from IES with a shareable fallback. Add it to
  `prepare_for_ractors!` or `make_app_shareable!`.
- **Callable-replacement** for Procs the gem holds in the app graph (like the
  shim's `Callable`/`NoOpProc` for `Rack::Files`/`ActionDispatch::SSL`).
- **NoOpLock** for Mutexes the gem holds (the shared app is read-only
  post-boot).

Open a PR adding the patch to `lib/ractor_rails_shim/patches/` (a new
per-concern file or an existing one) and an entry to `SHAREABLE_CONSTANTS`
for any unshareable constants the gem owns.

### Gems that are fundamentally incompatible (❌)
They're **process singletons by design**: background job processors
(Sidekiq), global SDK config (aws-sdk), or dry-rb's class-state-heavy
container system. These assume one mutable process-wide state graph — the
opposite of a frozen shared app. Run them in a **separate process** and talk
to them over IPC/Redis/an API. Don't try to load them into the shared app
graph.

## Auditing your own app

```sh
bundle exec ractor-rails-check --app   # app + gems (excludes Rails framework)
bundle exec ractor-rails-check        # everything
```

## Test project coverage (`Gemfile.test_project`)

Every gem in the reference production Gemfile, with the shim's verdict. Gems
outside the production path (dev/test groups, deploy CLIs) are listed at the
end for completeness. Statuses follow the legend above.

| Gem | Status | Notes |
|---|---|---|
| benchmark, base64 | ✅ | Stdlib shims (needed on Ruby 4.0 — see the Gemfile comment). No class-level state. |
| rails (~> 8.1.3) | ✅ verified | The shim's whole purpose; see the `rails` row above. |
| pg | ✅ | Connections are per-Ractor via AR's connection handler (shim-routed). |
| falcon (~> 0.55) | n/a | The server is the host process's job. In `:ractor` mode kino serves; Falcon backs the `:threaded` path with its own fiber-aware boot. Not part of the app graph. |
| redcarpet | ✅ | C extension, instance state only; `Markdown.new` per render. |
| async-http (~> 0.64) | ✅ patched | Six runtime-read constants (SCHEMES, HTTP2 CLIENT/SERVER_SETTINGS, HANDLERS, NO_RESPONSE, PROHIBITED_GET_HEADERS) are deep-frozen via the shareable-constants pipeline. Client/pool state is per-instance, built inside the requesting Ractor. |
| async-http-faraday | ✅ | Adapter registered into Faraday's registry at boot (Classes/Symbols — shareable); per-thread client cache is Ractor-local. |
| async-redis | ✅ | All state instance-level; each Ractor builds its own client/pool. |
| sass-rails / sassc-rails | ✅ | Compile-time only. Assets are precompiled at deploy; no request-time class state. Don't compile SCSS lazily inside a worker. |
| jbuilder | ✅ patched | `template_lookup_options` frozen; `Jbuilder.new` redefined with sentinel defaults; boot `key_format`/`ignore_nil`/`deep_format_keys` captured into shareable constants and replayed per worker (fresh formatter Mutex + cache each). |
| devise | ✅ verified | Existing patch. |
| devise-jwt | ✅ (see note) | No class/module state in-gem. Request-time JWT logic lives in the `warden-jwt_auth` dependency (config object via dry-configurable) — audit `warden-jwt_auth` before serving JWT auth from workers. |
| rack-attack | ⚠️ patched (with limitation) | Module state (configuration/cache/normalizer) routed per-Ractor; `@@proxies` snapshotted into the frozen `RACK_ATTACK_PROXIES` constant with a worker branch on `BaseProxy.proxies` (cvar reads are forbidden off-main even when the value is shareable — freezing in place is not enough); worker-safe `Cache.default_store` (bare `Rails` does not resolve in eval'd worker code) and real default-responder lambdas per worker (including the `retry-after` throttle header path); middleware `#call` worker branch. **Limitation:** DSL check blocks (throttle/blocklist/safelist/track) are main-Ractor Procs and cannot cross the boundary — workers run a default DSL-less config unless the app re-arms via `RactorRailsShim.on_worker_boot`. Counters still work (external store). |
| net-imap / net-pop / net-smtp | ✅ | Instance-level protocol clients. |
| matrix / mutex_m | ✅ | Plain libs. |
| redis | ⚠️ guidance | Per-Ractor clients (see the `redis` row above); ActionCable's server instance is already shim-routed via the ActionCable patch. |
| bcrypt | ✅ | C extension, instance state. |
| sprockets-rails | ⚠️ patched | Worker views get a frozen manifest snapshot (`SPROCKETS_MANIFEST_SNAPSHOT` answering `#assets`/`#files`), a fresh `precompiled_asset_checker` lambda, and manifest-only asset resolution (`resolve_assets_with → [:manifest]` off-main). Compilation stays in main/CI. |
| image_processing (~> 1.2) | ✅ | Instance transformers (mini_magick / vips); built per request. |
| aws-sdk-s3 | ❌ | Process-singleton config (`Aws.config`); run in a separate process (job/supervisor). |
| bootsnap | ✅ | Boot-time only (see above). |
| activeadmin | ❌ | The whole `ActiveAdmin::Application` graph is built from main-Ractor DSL blocks (Resources/Namespaces/Procs). Serve admin pages in the main process; per-worker rebuild is possible but re-executes app DSL per worker. |
| bootstrap / webpacker | ✅ | Asset gems (compile-time). Webpacker's runtime reads (manifest.json) are boot-time-only in production. |
| fast_jsonapi | ⚠️ patched (partial) | Serializer class metadata (12 attr_accessors per class) captured frozen + replayed per worker. Attribute/relationship procs that DON'T freeze cleanly are omitted (the field serializes to nil instead of crashing). |
| slim | ⚠️ partial | Slim's own pipeline is instance-based; the embedded-engine registry (`Slim::Embedded@engines` — Hash of Procs) and Temple's class-level option tables are the shared-state edges. Templates compiled lazily in a worker hit the registry read. Follow-up: audit Temple's option storage. |
| simple_form | ✅ patched | `FormBuilder.discovery_cache` per-Ractor; `@@wrappers` captured into a frozen snapshot (`SIMPLE_FORM_WRAPPERS`); worker readers for the two Proc-valued mattrs (`label_text`, `field_error_proc`) return Ractor-local lambdas with the same bodies. |
| sitemap_generator | ❌ (rake) | `SitemapGenerator::Sitemap` is one live mutable singleton in a constant (file I/O, name reservation, `instance_eval` of the user's sitemap.rb). Run `sitemap:refresh` in rake/main Ractor; keep the gem off the worker request path. |
| tzinfo | ✅ patched | Existing `tzinfo_data_source` patch. |
| translit | ✅ patched | The lazily-built Russian map is pre-warmed + deep-frozen; `Translit.russian` serves the frozen constant (no module-ivar write off-main). |
| telegram-bot | ✅ patched | `Telegram.bots`/`bot` clients built per-Ractor from the frozen `bots_config`; `default_async_job` worker branch (no runtime const_set); `UpdatesPoller` registry Ractor-local. |
| faraday | ✅ patched | Worker header keys map through a pure per-Ractor cache (upstream KeyMap holds a captured Mutex); middleware/adapter registries captured + promoted per-Ractor (**all** modules extending `Faraday::MiddlewareRegistry` — `Request`/`Response` register the default-rack-builder stack symbols, so a bare `Faraday.new` without a block must resolve `:url_encoded` off-main); `default_options`/`Env.member_set` per-Ractor; the `Utils` memo readers redefined on the singleton class (the module is `module_function` — instance-level defs would never override the callable singleton copies); `default_connection_options` gets a worker branch (the upstream reader sets a module ivar, which workers can only read); `NO_ARGUMENT`/`default_adapter_options` frozen; `Handler#klass` plain `const_get` off-main. |
| ferrum | ❌ (separate process) | Headless-Chrome driver — a driver process by design; never on the worker request path. |
| json-schema | ✅ patched | The heaviest cvar surface in the set: `@@mutex` untouched on main and skipped off-main (workers build their per-instance schema state lock-free — cvar reads are forbidden in workers even for a frozen NoOpLock); `@@default_opts` frozen + dup-merged; `@@schemas` per-Ractor; `@@validators`/`@@default_validator` captured frozen; `@@schema_reader`/`@@serializer`/`@@fake_uuid_generator`/`@@json_backend` per-Ractor; `@@use_multi_json` snapshotted (`JSON_USE_MULTI_JSON`, falling back to `Object.const_defined?(:MultiJson)`); `TYPE_CLASS_MAPPINGS` and `JSON::Util::UUID::Nil` frozen for the validate path. Schemas re-parse per Ractor (cache miss, not a crash). |
| prawn (~> 2.5) | ✅ patched | AFM font-data cache + metrics path per-Ractor (parsing is Ractor-safe); `Repeater.count` per-Ractor; `image_handler`/`Document.extensions` frozen in place at freeze time. |
| prawn-table (~> 0.2) | ✅ | Instance-level memoization only; tables/cells built inside the rendering Ractor. |
| mailgun-ruby (~> 1.2) | ✅ patched | All eight config ivars registered in `SHAREABLE_CLASS_IVARS` — frozen in place at freeze time, so the original accessors return shareable values in workers; each Ractor builds its own Faraday connection. |
| solid_queue (~> 1.7) | ✅ patched | Existing `solid_queue` patch (worker-side enqueue). The supervisor process runs separately. |
| mission_control-jobs | ✅ (see note) | All global state is mattr_accessor (shim-routed). The VALUES (applications/logger/importmap) are main-Ractor objects — populate per-Ractor slots via shim config if workers serve the Jobs UI. |
| feelings | ✅ patched | `judge`/`random`/`registry` per-Ractor (workers build their own judge/client); boot registry data captured into a frozen snapshot and re-registered into each worker's registry. |
| unicode_normalize (stdlib) | ✅ patched | `String#unicode_normalize` dies in workers out of the box (`Regexp.compile` leaves the three `REGEXP_*` constants unfrozen, and the `NF_HASH_*` memo Hashes are default-proc-backed Mutables). Regexps + `UNICODE_ENCODINGS` frozen; `normalize`/`normalized?` get worker branches that gsub/scan with blocks feeding per-Ractor memo Hashes (`MAX_HASH_LENGTH` cap preserved, `nfc_one`/`nfd_one` recomputed). Main keeps the upstream memoization hashes untouched. |

Out of scope (not on the production request path): `kamal`/`thruster`
(deploy/proxy CLIs, `require: false`), `annotate` (dev), and the
development/test group (`dotenv-rails`, `byebug`, `rubocop*`,
`shoulda-matchers`, `minitest-reporters`, `mutineer`, `minitest-mock`,
`simplecov`, `foreman`, `rbs`, `steep`, `web-console`, `listen`, `pry`).
These load at boot or in dev tooling only; the frozen worker request path
never touches them. `ruby_llm` is pinned at 2.1.0 in the Gemfile (audited
2.1.1 — patch applies to both).

The report lists every class ivar / class var holding an unshareable value,
tagged by kind. Cross-reference each finding against this matrix:

- **`(mattr/cattr — shim targets)`** tag → already rerouted; no action.
- Untagged `@@foo` → likely a `mattr_accessor` the macro caught, or a raw
  class var needing a patch.
- Raw `@foo` → add a targeted patch (see "Gems that need a patch" above) or
  open an upstream issue.

For gems not in this matrix, the decision tree is:
1. Does it use `mattr_accessor`/`class_attribute`? → shim fixes it (✅).
2. Does it hold class ivars/vars directly? → needs a patch (⚠️).
3. Is it a process singleton with background threads + global mutable state?
   → incompatible, run in a separate process (❌).
4. Is it only used at boot time (not per-request)? → irrelevant in production
   (the shared app is frozen after boot).
